{-# LANGUAGE DeriveGeneric #-}

module Network.RTM.Slack.Server
    ( sendMessage
    , updateMessage
    , serveSlackHandle
    , serveSlack
    , SlackCallback
    , SlackState (..)
    , slackSelf
    , slackTeam
    , slackUsers
    , slackChannels
    , slackGroups
    , slackIMs
    , slackBots
    , stateFromSession
    ) where

import ClassyPrelude
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types
import Control.Distributed.Process.ManagedProcess
import Control.Distributed.Process.Extras.Time
import Network.RTM.Slack.Maintainer
import qualified Web.Slack.Handle as S
import qualified Web.Slack.WebAPI as SW
import Control.Monad.Except
import Data.Binary

data MsgSend = MsgSend ProcessId S.ChannelId Text deriving (Typeable, Generic)
instance Binary MsgSend

data MsgUpdate = MsgUpdate S.ChannelId S.SlackTimeStamp Text deriving (Typeable, Generic)
instance Binary MsgUpdate

data MsgSent = MsgSent Int S.SlackTimeStamp deriving (Typeable, Generic)
instance Binary MsgSent

sendMessage :: ProcessId -> S.ChannelId -> Text -> Process S.SlackTimeStamp
sendMessage pid chId msg = do
    me <- getSelfPid
    cast pid (MsgSend me chId msg) >> expect

updateMessage :: ProcessId -> S.ChannelId -> S.SlackTimeStamp -> Text -> Process ()
updateMessage pid chId t msg = cast pid $ MsgUpdate chId t msg

data ServerState = ServerState SlackState (Map Int ProcessId)

serveSlackHandle :: S.SlackHandle -> SlackCallback -> Process ()
serveSlackHandle h c = do
                        me <- getSelfPid
                        serve me init_ defaultProcess {
                            apiHandlers = [
                                handleCast $ \(ServerState s ms) (MsgSend pid chId msg) -> do
                                    msgId <- liftIO $ S.sendMessage h chId msg
                                    continue . ServerState s $ insertMap msgId pid ms,
                                handleCast $ \s (MsgUpdate chId t msg) -> do
                                    void . liftIO . runExceptT $ SW.chat_update (S.getConfig h) chId t msg []
                                    continue s,
                                handleCast $ \(ServerState s ms) (MsgSent msgId t) -> do
                                    ms' <- case updateLookupWithKey (const $ const Nothing) msgId ms of
                                        (Nothing, ms') -> return ms'
                                        (Just pid, ms') -> send pid t >> return ms'
                                    continue $ ServerState s ms',
                                handleCast $ \(ServerState _ ms) a -> continue $ ServerState a ms
                            ]
                       }
  where
    init_ pid = do
        void . spawnLocal $ maintainState h $ handle_ pid
        return $ InitOk (ServerState (stateFromSession $ S.getSession h) mempty) Infinity
    handle_ pid e s = do
        cast pid s
        case e of
            (S.MessageResponse msgId t _)   -> cast pid $ MsgSent msgId t
            _                               -> return ()
        c e s

serveSlack :: Text -> SlackCallback -> Process ()
serveSlack t c = Process $ ReaderT $ \p -> S.withSlackHandle (S.SlackConfig $ unpack t)
                                            $ \h -> runReaderT (unProcess $ serveSlackHandle h c) p
