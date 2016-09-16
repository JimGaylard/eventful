{-# LANGUAGE QuasiQuotes #-}  -- This is here so Hlint doesn't choke

-- | Defines an Sqlite event store.

module Eventful.Store.Sqlite
  ( SqliteEvent (..)
  , SqliteEventId
  , migrateSqliteEvent
  , getProjectionIds
  , bulkInsert
  , sqliteMaxVariableNumber
  , SqliteEventStore
  , sqliteEventStore
  , JSONString
  ) where

import Control.Monad.Reader
import Data.List.Split (chunksOf)
import Data.Maybe (listToMaybe, maybe)
import Database.Persist
import Database.Persist.Sql
import Database.Persist.TH

import Eventful.Store.Class
import Eventful.Store.Sqlite.Internal
import Eventful.UUID

share [mkPersist sqlSettings, mkMigrate "migrateSqliteEvent"] [persistLowerCase|
SqliteEvent sql=events
    Id SequenceNumber sql=sequence_number
    projectionId UUID
    version EventVersion
    data JSONString
    UniqueAggregateVersion projectionId version
    deriving Show
|]

sqliteEventToStored :: Entity SqliteEvent -> StoredEvent JSONString
sqliteEventToStored (Entity (SqliteEventKey seqNum) (SqliteEvent uuid version data')) =
  StoredEvent uuid version seqNum data'

-- sqliteEventFromSequenced :: StoredEvent event -> Entity SqliteEvent
-- sqliteEventFromSequenced (StoredEvent uuid version seqNum event) =
--   Entity (SqliteEventKey seqNum) (SqliteEvent uuid data' version)
--   where data' = toStrict (encode event)

getProjectionIds :: (MonadIO m) => ReaderT SqlBackend m [UUID]
getProjectionIds =
  fmap unSingle <$> rawSql "SELECT DISTINCT projection_id FROM events" []

getSqliteAggregateEvents :: (MonadIO m) => UUID -> ReaderT SqlBackend m [StoredEvent JSONString]
getSqliteAggregateEvents uuid = do
  entities <- selectList [SqliteEventProjectionId ==. uuid] [Asc SqliteEventVersion]
  return $ sqliteEventToStored <$> entities

getAllEventsFromSequence :: (MonadIO m) => SequenceNumber -> ReaderT SqlBackend m [StoredEvent JSONString]
getAllEventsFromSequence seqNum = do
  entities <- selectList [SqliteEventId >=. SqliteEventKey seqNum] [Asc SqliteEventId]
  return $ sqliteEventToStored <$> entities

maxEventVersion :: (MonadIO m) => UUID -> ReaderT SqlBackend m EventVersion
maxEventVersion uuid =
  let rawVals = rawSql "SELECT IFNULL(MAX(version), -1) FROM events WHERE projection_id = ?" [toPersistValue uuid]
  in maybe 0 unSingle . listToMaybe <$> rawVals

-- | Insert all items but chunk so we don't hit SQLITE_MAX_VARIABLE_NUMBER
bulkInsert
  :: ( MonadIO m
     , PersistStore (PersistEntityBackend val)
     , PersistEntityBackend val ~ SqlBackend
     , PersistEntity val
     )
  => [val]
  -> ReaderT (PersistEntityBackend val) m [Key val]
bulkInsert items = concat <$> forM (chunksOf sqliteMaxVariableNumber items) insertMany

-- | Search for SQLITE_MAX_VARIABLE_NUMBER here:
-- https://www.sqlite.org/limits.html
sqliteMaxVariableNumber :: Int
sqliteMaxVariableNumber = 999


data SqliteEventStore
  = SqliteEventStore
  { _sqliteEventStoreConnectionPool :: ConnectionPool
  }

sqliteEventStore :: (MonadIO m) => ConnectionPool -> m SqliteEventStore
sqliteEventStore pool = do
  -- Run migrations
  _ <- liftIO $ runSqlPool (runMigrationSilent migrateSqliteEvent) pool

  -- Create index on projection_id so retrieval is very fast
  liftIO $ runSqlPool
    (rawExecute "CREATE INDEX IF NOT EXISTS projection_id_index ON events (projection_id)" [])
    pool

  return $ SqliteEventStore pool

instance (MonadIO m) => EventStore m SqliteEventStore JSONString where
  getAllUuids = sqliteEventStoreGetUuids
  getEventsRaw = sqliteEventStoreGetEvents
  storeEventsRaw = sqliteEventStoreStoreEvents
  latestEventVersion = sqliteEventStoreLatestEventVersion
  getSequencedEvents = sqliteEventStoreGetSequencedEvents

sqliteEventStoreGetUuids :: (MonadIO m) => SqliteEventStore -> m [UUID]
sqliteEventStoreGetUuids (SqliteEventStore pool) =
  liftIO $ runSqlPool getProjectionIds pool

sqliteEventStoreGetEvents :: (MonadIO m) => SqliteEventStore -> UUID -> m [StoredEvent JSONString]
sqliteEventStoreGetEvents (SqliteEventStore pool) uuid =
  liftIO $ runSqlPool (getSqliteAggregateEvents uuid) pool

sqliteEventStoreGetSequencedEvents :: (MonadIO m) => SqliteEventStore -> SequenceNumber -> m [StoredEvent JSONString]
sqliteEventStoreGetSequencedEvents (SqliteEventStore pool) seqNum =
  liftIO $ runSqlPool (getAllEventsFromSequence seqNum) pool

sqliteEventStoreStoreEvents
  :: (MonadIO m)
  => SqliteEventStore -> UUID -> [JSONString] -> m [StoredEvent JSONString]
sqliteEventStoreStoreEvents (SqliteEventStore pool) uuid events =
  liftIO $ runSqlPool doInsert pool
  where
    doInsert = do
      versionNum <- maxEventVersion uuid
      let entities = zipWith (SqliteEvent uuid) [versionNum + 1..] events
      sequenceNums <- bulkInsert entities
      return $ zipWith3 (\(SqliteEventKey seqNum) vers event -> StoredEvent uuid vers seqNum event)
        sequenceNums [versionNum + 1..] events

sqliteEventStoreLatestEventVersion
  :: (MonadIO m)
  => SqliteEventStore -> UUID -> m EventVersion
sqliteEventStoreLatestEventVersion (SqliteEventStore pool) uuid =
  liftIO $ runSqlPool (maxEventVersion uuid) pool
