{-# language PatternSynonyms #-}
module MusicScroll.LyricsPipeline where

-- | Discriminate between getting the lyrics from SQLite or the web.

import Control.Concurrent.MVar
import Control.Applicative (Alternative(..))
import Control.Monad.Trans.Reader (ReaderT, runReaderT)
import Database.SQLite.Simple
import Pipes
import qualified Pipes.Prelude as PP

import MusicScroll.DatabaseUtils
import MusicScroll.TrackInfo
import MusicScroll.Web
import MusicScroll.Providers.Utils (Lyrics(..))
import MusicScroll.Providers.AZLyrics (azLyricsInstance)
import MusicScroll.Providers.MusiXMatch (musiXMatchInstance)

data SongByOrigin = DB | Web
data SearchResult = GotLyric SongByOrigin TrackInfo Lyrics
                  | ErrorOn ErrorCause

data ErrorCause = NotOnDB TrackByPath | NoLyricsOnWeb TrackInfo | ENoSong

pattern OnlyMissingArtist :: ErrorCause
pattern OnlyMissingArtist <- NotOnDB (TrackByPath {tpArtist = Nothing, tpTitle = Just _})

noRepeatedFilter :: Functor m => Pipe TrackIdentifier TrackIdentifier m a
noRepeatedFilter = do firstSong <- await
                      yield firstSong
                      loop firstSong
  where
    loop prevSong = do newSong <- await
                       if newSong /= prevSong
                         then yield newSong *> loop newSong
                         else loop prevSong

getLyricsP :: MVar Connection -> Pipe TrackIdentifier SearchResult IO a
getLyricsP connMvar = PP.mapM go
  where go :: TrackIdentifier -> IO SearchResult
        go ident = runReaderT (either caseByPath caseByInfoGeneral ident) connMvar

getLyricsFromWebP :: Pipe TrackInfo SearchResult IO a
getLyricsFromWebP = PP.mapM caseByInfoWeb

caseByInfoGeneral :: TrackInfo -> ReaderT (MVar Connection) IO SearchResult
caseByInfoGeneral track =
  let local = caseByInfoLocal track
      web = caseByInfoWeb track
      err = pure (ErrorOn (NoLyricsOnWeb track))
  in local <|> web <|> err

caseByInfoWebP :: (MonadIO m, Alternative m) => TrackInfo -> m SearchResult
caseByInfoWebP track =
  let web = caseByInfoWeb track
      err = pure (ErrorOn (NoLyricsOnWeb track))
  in web <|> err

caseByInfoLocal :: TrackInfo -> ReaderT (MVar Connection) IO SearchResult
caseByInfoLocal track =
  GotLyric DB track <$> getDBLyrics (tUrl track)

caseByInfoWeb :: (MonadIO m, Alternative m) => TrackInfo -> m SearchResult
caseByInfoWeb track = GotLyric Web track <$>
  (getLyricsFromWeb azLyricsInstance track
   <|> getLyricsFromWeb musiXMatchInstance track)

caseByPath :: TrackByPath -> ReaderT (MVar Connection) IO SearchResult
caseByPath track =
  ((uncurry (GotLyric DB)) <$> getDBSong (tpPath track)) <|>
  pure (ErrorOn (NotOnDB track))

saveOnDb :: MVar Connection -> Pipe SearchResult SearchResult IO a
saveOnDb mconn = PP.chain go
  where go :: SearchResult -> IO ()
        go (GotLyric Web info lyr) = runReaderT (insertDBLyrics info lyr) mconn
        go _otherwise = pure ()
