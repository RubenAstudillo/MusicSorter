{-# language OverloadedStrings, FlexibleContexts #-}
module MusicScroll.DBusSignals
  ( mediaPropChangeRule
  , waitForChange
  , changeMusicClient
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TMVar (TMVar, takeTMVar, newEmptyTMVar, putTMVar)
import Control.Monad.State.Class (MonadState(..))
import Data.Foldable (find)
import Data.Maybe (fromJust)
import Pipes

import DBus.Client
import DBus

import MusicScroll.DBusNames
import MusicScroll.ConnState

mediaPropChangeRule, busNameAddedRule :: MatchRule
mediaPropChangeRule = matchAny
  { matchPath      = pure mediaObject
  , matchInterface = pure "org.freedesktop.DBus.Properties"
  , matchMember    = pure "PropertiesChanged" }
busNameAddedRule = matchAny
  { matchSender    = pure dbusBus -- unique name
  , matchPath      = pure "/org/freedesktop/DBus"
  , matchInterface = pure "org.freedesktop.DBus"
  , matchMember    = pure "NameOwnerChanged" }

waitForChange :: (MonadState ConnState m, MonadIO m) => MatchRule -> m ()
waitForChange rule = do
  (ConnState client _) <- get
  liftIO $ do trigger       <- atomically newEmptyTMVar
              disarmHandler <- armSignal client trigger rule
              _ <- atomically $ takeTMVar trigger
              removeMatch client disarmHandler

armSignal :: Client -> TMVar () -> MatchRule -> IO SignalHandler
armSignal client trigger rule =
  addMatch client rule (\_ -> atomically ( putTMVar trigger () ))

changeMusicClient :: (MonadState ConnState m, MonadIO m) => m ()
changeMusicClient =
  do (ConnState client _) <- get
     availableStatus <- liftIO $ traverse (checkName client) allBuses
     let taggedBuses = zip allBuses availableStatus
     case fst <$> find snd taggedBuses of
       Just newBus -> put (ConnState client newBus)
       Nothing     -> do waitForChange busNameAddedRule
                         changeMusicClient

checkName :: Client -> BusName -> IO Bool
checkName client name = do
  returnCall <- call_ client
      (methodCall "/org/freedesktop/DBus" "org.freedesktop.DBus" "NameHasOwner")
        { methodCallDestination = Just dbusBus
        , methodCallBody = [toVariant name] }
  -- We assume this call is correct, as it's done to the master dbus
  -- object. So fromJust/head are safe.
  return . fromJust . fromVariant . head . methodReturnBody $ returnCall
