module MusicScroll.LyricsPipeline (lyricsThread, sizeOfQueue) where

-- | Discriminate between getting the lyrics from SQLite or the web.

import Control.Concurrent.Async (withAsync, waitAnyCancel)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TBQueue (TBQueue, readTBQueue, writeTBQueue, newTBQueue)
import Control.Applicative (Alternative(..))
import Control.Monad.Trans.State
import Control.Monad.IO.Class (liftIO)
import Control.Monad (forever, when)
import Data.Bifunctor (second)
import Numeric.Natural (Natural)
import Data.Functor (void)

import MusicScroll.DatabaseUtils (getDBLyrics, getDBSong)
import MusicScroll.TrackInfo
import MusicScroll.AZLyrics (getLyricsFromWeb)
import MusicScroll.UIEvent

sizeOfQueue :: Natural
sizeOfQueue = 5

lyricsThread :: TBQueue TrackIdentifier -> TBQueue UIEvent -> IO ()
lyricsThread input output =
  do songFilterChan <- atomically (newTBQueue sizeOfQueue)
     let seenSongThread' = seenSongsThread input songFilterChan
     withAsync (evalStateT seenSongThread' Nothing) $ \seenSongsA ->
       withAsync (getLyricsThread songFilterChan output) $ \getLyricsA ->
         void $ waitAnyCancel [seenSongsA, getLyricsA]

seenSongsThread :: TBQueue TrackIdentifier -> TBQueue TrackIdentifier
                -> StateT (Maybe TrackIdentifier) IO a
seenSongsThread input output = forever $
  do trackIdent <- second cleanTrack <$>
                   liftIO (atomically (readTBQueue input))
     notSeen <- (/=) <$> get <*> pure (Just trackIdent)
     when notSeen $ do put (pure trackIdent)
                       liftIO . atomically $ writeTBQueue output trackIdent

getLyricsThread :: TBQueue TrackIdentifier -> TBQueue UIEvent -> IO a
getLyricsThread input output = forever $
  do trackIdent <- atomically (readTBQueue input)
     event <- either caseMetadataErr caseTrack trackIdent
     atomically $ writeTBQueue output event

caseTrack :: TrackInfo -> IO UIEvent
caseTrack track =
  let tryGetLyrics = getDBLyrics (tUrl track) <|> getLyricsFromWeb track
  in (GotLyric track <$> tryGetLyrics) <|> pure (ErrorOn NoLyricsOnWeb)

caseMetadataErr :: TrackByPath -> IO UIEvent
caseMetadataErr (TrackByPath songPath cause) =
  ((uncurry GotLyric) <$> getDBSong songPath) <|>
  pure (ErrorOn (NotOnDB cause))
