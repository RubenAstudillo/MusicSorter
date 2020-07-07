{-# language OverloadedStrings, RecordWildCards, BangPatterns, PatternSynonyms #-}
module MusicScroll.UIEvent where

import           Control.Monad (unless, forever)
import           Data.GI.Gtk.Threading (postGUISync)
import           Data.Maybe (isNothing)
import           Data.Text as T
import qualified GI.Gtk as Gtk
import Pipes

import           MusicScroll.TrackInfo (TrackInfo(..), TrackByPath(..))
import           MusicScroll.Providers.Utils (Lyrics(..))


data SongByOrigin = DB | Web
data SearchResult = GotLyric SongByOrigin TrackInfo Lyrics
                  | ErrorOn ErrorCause

data ErrorCause = NotOnDB TrackByPath | NoLyricsOnWeb TrackInfo | ENoSong

pattern OnlyMissingArtist :: ErrorCause
pattern OnlyMissingArtist <- NotOnDB (TrackByPath {tpArtist = Nothing, tpTitle = Just _})

data AppContext = AppContext
  { mainWindow     :: Gtk.Window
  , titleLabel     :: Gtk.Label
  , artistLabel    :: Gtk.Label
  , lyricsTextView :: Gtk.TextView
  , errorLabel     :: Gtk.Label
  , titleSuplementEntry   :: Gtk.Entry
  , artistSuplementEntry  :: Gtk.Entry
  , suplementAcceptButton :: Gtk.Button
  , keepArtistNameCheck   :: Gtk.CheckButton
  }

errorMsg :: ErrorCause -> Text
errorMsg (NotOnDB trackPath)
  | isNothing (tpArtist trackPath) =
        "No lyrics found by hash on the song file, try to suplement the song's\
        \ artist metadata to try to get it from the web."
  | isNothing (tpTitle trackPath) =
        "No lyrics found by hash on the song file, try to suplement the song's\
        \ title metadata to try to get it from the web."
  | otherwise = "This case should not happen"
errorMsg ENoSong = "No song found, this is usually an intermediary state."
errorMsg (NoLyricsOnWeb _) = "Lyrics provider didn't have that song."

extractGuess :: ErrorCause -> Maybe (Text, Text)
extractGuess (NoLyricsOnWeb (TrackInfo {..})) =
  pure (tTitle, tArtist)
extractGuess (NotOnDB (TrackByPath {..})) =
  let def = maybe mempty id in pure (def tpTitle, def tpArtist)
extractGuess _ = Nothing

-- | Only usable inside a gtk context
updateNewLyrics :: AppContext -> (TrackInfo, Lyrics) -> IO ()
updateNewLyrics ctx@(AppContext {..}) (track, Lyrics singleLyrics) =
  let !bytesToUpdate = fromIntegral $ T.length singleLyrics
  in postGUISync $ do
    Gtk.labelSetText errorLabel mempty
    Gtk.labelSetText titleLabel (tTitle track)
    Gtk.labelSetText artistLabel (tArtist track)
    lyricsBuffer <- Gtk.textViewGetBuffer lyricsTextView
    Gtk.textBufferSetText lyricsBuffer singleLyrics bytesToUpdate
    updateSuplementalGuess ctx (mempty, mempty)

dischargeOnUI :: AppContext -> Consumer SearchResult IO a
dischargeOnUI ctx = forever (dischargeOnUISingle ctx)

dischargeOnUISingle :: AppContext -> Consumer SearchResult IO ()
dischargeOnUISingle ctx = do
  res <- await
  liftIO $ case res of
    GotLyric _ info lyr -> updateNewLyrics ctx (info, lyr)
    ErrorOn cause -> updateErrorCause ctx cause

updateErrorCause :: AppContext -> ErrorCause -> IO ()
updateErrorCause ctx@(AppContext {..}) cause = postGUISync $
  do Gtk.labelSetText titleLabel "No Song available"
     Gtk.labelSetText artistLabel mempty
     lyricsBuffer <- Gtk.textViewGetBuffer lyricsTextView
     Gtk.textBufferSetText lyricsBuffer mempty 0
     Gtk.labelSetText errorLabel (errorMsg cause)
     maybe (return ()) (updateSuplementalGuess ctx) (extractGuess cause)

updateSuplementalGuess :: AppContext -> (Text, Text) -> IO ()
updateSuplementalGuess (AppContext {..}) (guessTitle, guessArtist) =
  do Gtk.entrySetText titleSuplementEntry guessTitle
     shouldMaintainArtistSupl <- Gtk.getToggleButtonActive keepArtistNameCheck
     unless shouldMaintainArtistSupl $
       Gtk.entrySetText artistSuplementEntry guessArtist
