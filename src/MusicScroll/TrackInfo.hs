{-# language OverloadedStrings, NamedFieldPuns #-}
module MusicScroll.TrackInfo
  ( TrackInfo(..)
  , TrackInfoError(..)
  , MetadataError(..)
  , SongFilePath
  , TrackIdentifier
  , tryGetInfo
  , cleanTrack
  ) where

import           Prelude hiding (readFile)
import           Control.Monad (join)
import           DBus
import           DBus.Client
import           Data.Bifunctor (first)
import           Data.Function ((&))
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromJust)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Char (isAlpha)

import           MusicScroll.DBusNames

data TrackInfo = TrackInfo
  { tTitle  :: Text
  , tArtist :: Text -- xesam:artist is weird
  , tUrl    :: SongFilePath
  } deriving (Eq, Show) -- TODO: better eq instance

data MetadataError = NoArtist | NoTitle deriving (Eq)
type SongFilePath = FilePath
type TrackIdentifier = Either (SongFilePath, MetadataError) TrackInfo

data TrackInfoError = NoMusicClient MethodError
                    | NoMetadata (SongFilePath, MetadataError)

-- An exception here means that either there is not a music player
-- running or what it is running it's not a song. Either way we should
-- wait for a change on the dbus connection to try again.
tryGetInfo :: Client -> BusName -> IO (Either TrackInfoError TrackInfo)
tryGetInfo client busName = do
    metadata <- getPropertyValue client
                  (methodCall mediaObject mediaInterface "Metadata") {
                    methodCallDestination = pure busName
                  } & fmap (first NoMusicClient)
    return . join $ obtainTrackInfo <$> metadata

obtainTrackInfo :: Map Text Variant -> Either TrackInfoError TrackInfo
obtainTrackInfo metadata =
  let lookup :: IsVariant a => MetadataError -> Text -> Either MetadataError a
      lookup cause name =
        let mvalue = Map.lookup name metadata >>= fromVariant
        in maybe (Left cause) Right mvalue

      songPath :: SongFilePath
      songPath = fromJust $ Map.lookup "xesam:url" metadata >>= fromVariant

      track = TrackInfo <$> lookup NoTitle "xesam:title"
          <*> xesamArtistFix (lookup NoArtist "xesam:artist")
                             (lookup NoArtist "xesam:artist")
          <*> pure songPath
  in first (\cause -> NoMetadata (songPath, cause)) track

-- xesam:artist by definition should return a `[Text]`, but in practice
-- it returns a `Text`. This function makes it always return `Text`.
xesamArtistFix :: Either MetadataError Text
               -> Either MetadataError [Text] -> Either MetadataError Text
xesamArtistFix (Right title) _ = pure title
xesamArtistFix (Left _) (Right arr) | (title : _) <- arr = pure title
xesamArtistFix left _ = left

cleanTrack :: TrackInfo -> TrackInfo
cleanTrack t@(TrackInfo {tTitle}) = t { tTitle = cleanTitle tTitle }

-- Remove .mp3 and numbers from the title.
cleanTitle :: Text -> Text
cleanTitle title0 =
  let (title1, format) = first T.init $ T.breakOnEnd "." title0
      title2 = if elem format musicFormats then title1 else title0
  in T.dropWhile (not . isAlpha) title2

musicFormats :: [Text]
musicFormats = ["mp3", "flac", "ogg", "wav", "acc", "opus", "webm"]
