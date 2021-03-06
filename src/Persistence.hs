{-# LANGUAGE RankNTypes, FlexibleContexts, FlexibleInstances, MultiParamTypeClasses, ConstraintKinds, DeriveAnyClass, DeriveGeneric, TypeApplications, OverloadedStrings, BangPatterns #-}
module Persistence where

import Prelude hiding (log)

import Persistence.Migration

import Control.Monad.Reader
import Control.Monad (forM_)
import Database.Beam.Migrate.Simple
import Database.Beam.Postgres.Migrate as Pgm
import Database.PostgreSQL.Simple
import qualified Database.Beam.Postgres as Pg
import qualified Database.Beam.Postgres.Full as Pgf
import Database.Beam as B
import Database.Beam.Backend.SQL
import Colog
import Data.Maybe
import Data.Time
import Data.Text as T
import Data.Pool
import Data.Text.Encoding (encodeUtf8)
import Types as T
import Network

newtype Persistence = Persistence { _runBeam :: forall a. Pg.Pg a -> IO a }

type WithBeam env m = (MonadReader env m, MonadIO m, HasBeam env)

class HasBeam env where
    getPersistence :: env -> Persistence

instance HasBeam Persistence where
    getPersistence = id

allowDestructive :: Monad m => BringUpToDateHooks m
allowDestructive = defaultUpToDateHooks { runIrreversibleHook = pure True }

migrateDB = bringUpToDateWithHooks allowDestructive Pgm.migrationBackend initialSetupStep

smhiDb :: DatabaseSettings Pg.Postgres SmhiDb
smhiDb = unCheckDatabase $ evaluateDatabase initialSetupStep

initPersistence logAction cs = do
    connPool <- createPool (connectPostgreSQL (encodeUtf8 cs)) close 2 60 10
    let logger msg = usingLoggerT logAction . logDebug $ "[beam] " <> T.pack msg
    let runBeam pg = withResource connPool $ \c -> Pg.runBeamPostgresDebug logger c pg
    Just !db <- runBeam migrateDB
    return $ Persistence runBeam

upsertForecasts :: (WithLog env Message m, WithBeam env m) => [Forecast] -> m ()
upsertForecasts forecasts = do
   Persistence runBeam <- asks getPersistence
   liftIO . runBeam . runInsert $
       Pgf.insert (smhiForecasts smhiDb) (insertValues forecasts) $
           Pgf.onConflict
            Pgf.anyConflict
            Pgf.onConflictDoNothing

upsertObservations :: (WithLog env Message m, WithBeam env m) => [Observation] -> m ()
upsertObservations observations = do
   Persistence runBeam <- asks getPersistence
   liftIO . runBeam . runInsert $
       Pgf.insert (smhiObservations smhiDb) (insertValues observations) $
           Pgf.onConflict
            Pgf.anyConflict
            Pgf.onConflictDoNothing

hoursSinceEpoch_ c = valueExpr_ $ as_ @Int $ customExpr_ (\t -> "CAST (EXTRACT(EPOCH FROM " <> t <> ") AS Int)/3600") c


getHours' table = do
  Persistence runBeam <- asks getPersistence
  liftIO . runBeam . runSelectReturningList . select $ all_ (table smhiDb)

getHours :: (WithLog env Message m, WithBeam env m) => RecordType -> m [Hour]
getHours Forecasts    = getHours' smhiForecasts
getHours Observations = getHours' smhiObservations

getMAE :: (WithLog env Message m, WithBeam env m) => m [MAE]
getMAE = do
    Persistence runBeam <- asks getPersistence
    r <- liftIO . runBeam . runSelectReturningList . select $
        aggregate_ (\(obs, fcs) -> let age = group_ $ hoursSinceEpoch_ (hourStart obs) - hoursSinceEpoch_ (T.hourTime fcs)
                                       err = fromMaybe_ 0 (avg_ $ abs (hourTemperature fcs - hourTemperature obs))
                                       mn  = fromMaybe_ 0 (min_ $ abs (hourTemperature fcs - hourTemperature obs))
                                       mx  = fromMaybe_ 0 (max_ $ abs (hourTemperature fcs - hourTemperature obs))

                                    in (age, err, mx, mn)) $ do
            fcs <- all_ (smhiForecasts smhiDb)
            obs <- all_ (smhiObservations smhiDb)

            guard_ (hourStart obs ==. hourStart fcs)
            pure (obs, fcs)
    return $ uncurry4 MAE <$> r

uncurry4 f (a,b,c,d) = f a b c d
