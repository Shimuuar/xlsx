{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE DeriveGeneric #-}

-- | This module provides a function for reading .xlsx files
module Codec.Xlsx.Parser
  ( toXlsx
  , toXlsxEither
  , ParseError(..)
  , Parser
  ) where


import qualified Codec.Archive.Zip as Zip
import Control.Applicative
import Control.Arrow (left)
import Control.Error.Safe (headErr)
import Control.Error.Util (note)
import Control.Lens hiding (element, views, (<.>))
import Control.Monad.Except (catchError, throwError)
import qualified Data.ByteString.Lazy as L
import Data.ByteString.Lazy.Char8 ()
import Data.List
import qualified Data.Map as M
import Data.Maybe
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as T
import Data.Traversable
import GHC.Generics (Generic)
import Prelude hiding (sequence)
import System.FilePath.Posix
import Text.XML as X
import Text.XML.Cursor

import Codec.Xlsx.Parser.Internal
import Codec.Xlsx.Parser.Internal.PivotTable
import Codec.Xlsx.Types
import Codec.Xlsx.Types.Internal
import Codec.Xlsx.Types.Internal.CfPair
import Codec.Xlsx.Types.Internal.CommentTable as CommentTable
import Codec.Xlsx.Types.Internal.ContentTypes as ContentTypes
import Codec.Xlsx.Types.Internal.CustomProperties
       as CustomProperties
import Codec.Xlsx.Types.Internal.DvPair
import Codec.Xlsx.Types.Internal.Relationships as Relationships
import Codec.Xlsx.Types.Internal.SharedStringTable
import Codec.Xlsx.Types.PivotTable.Internal

-- | Reads `Xlsx' from raw data (lazy bytestring)
toXlsx :: L.ByteString -> Xlsx
toXlsx = either (error . show) id . toXlsxEither

data ParseError = InvalidZipArchive
                | MissingFile FilePath
                | InvalidFile FilePath
                | InvalidRef FilePath RefId
                | InconsistentXlsx Text
                deriving (Eq, Show, Generic)

type Parser = Either ParseError

-- | Reads `Xlsx' from raw data (lazy bytestring), failing with Left on parse error
toXlsxEither :: L.ByteString -> Parser Xlsx
toXlsxEither bs = do
  ar <- left (const InvalidZipArchive) $ Zip.toArchiveOrFail bs
  sst <- getSharedStrings ar
  contentTypes <- getContentTypes ar
  (wfs, names, cacheSources) <- readWorkbook ar
  sheets <- forM wfs $ \wf -> do
      sheet <- extractSheet ar sst contentTypes cacheSources wf
      return (wfName wf, sheet)
  CustomProperties customPropMap <- getCustomProperties ar
  return $ Xlsx sheets (getStyles ar) names customPropMap

data WorksheetFile = WorksheetFile { wfName :: Text
                                   , wfPath :: FilePath
                                   }
                   deriving (Show, Generic)

type Caches = [(CacheId, (Text, CellRef, [CacheField]))]

extractSheet :: Zip.Archive
             -> SharedStringTable
             -> ContentTypes
             -> Caches
             -> WorksheetFile
             -> Parser Worksheet
extractSheet ar sst contentTypes caches wf = do
  let filePath = wfPath wf
  file <- note (MissingFile filePath) $ Zip.fromEntry <$> Zip.findEntryByPath filePath ar
  cur <- fmap fromDocument . left (\_ -> InvalidFile filePath) $
         parseLBS def file
  sheetRels <- getRels ar filePath

  -- The specification says the file should contain either 0 or 1 @sheetViews@
  -- (4th edition, section 18.3.1.88, p. 1704 and definition CT_Worksheet, p. 3910)
  let  sheetViewList = cur $/ element (n_ "sheetViews") &/ element (n_ "sheetView") >=> fromCursor
       sheetViews = case sheetViewList of
         []    -> Nothing
         views -> Just views

  let commentsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"
      commentTarget :: Maybe FilePath
      commentTarget = relTarget <$> findRelByType commentsType sheetRels
      legacyDrRId = cur $/ element (n_ "legacyDrawing") >=> fromAttribute (odr"id")
      legacyDrPath = fmap relTarget . flip Relationships.lookup sheetRels  =<< listToMaybe legacyDrRId

  commentsMap :: Maybe CommentTable <- maybe (Right Nothing) (getComments ar legacyDrPath) commentTarget

  -- Likewise, @pageSetup@ also occurs either 0 or 1 times
  let pageSetup = listToMaybe $ cur $/ element (n_ "pageSetup") >=> fromCursor

      cws = cur $/ element (n_ "cols") &/ element (n_ "col") >=> fromCursor

      (rowProps, cells0) = collect $ cur $/ element (n_ "sheetData") &/ element (n_ "row") >=> parseRow
      parseRow :: Cursor -> [(Int, Maybe RowProperties, [(Int, Int, Cell)])]
      parseRow c = do
        r <- fromAttribute "r" c
        let prop = RowProps
              { rowHeight = 
                  if fromAttribute "customHeight" c == [True]
                  then listToMaybe $ fromAttribute "ht" c
                  else Nothing
              , rowStyle  =
                  listToMaybe $ fromAttribute "s" c
              , rowHidden  =
                  case fromAttribute "hidden" c of
                    []  -> False
                    f:_ -> f
              }
        return ( r
               , if prop == def then Nothing else Just prop
               , c $/ element (n_ "c") >=> parseCell
               )
      parseCell :: Cursor -> [(Int, Int, Cell)]
      parseCell cell = do
        ref <- fromAttribute "r" cell
        let
          s = listToMaybe $ cell $| attribute "s" >=> decimal
          t = fromMaybe "n" $ listToMaybe $ cell $| attribute "t"
          d = listToMaybe $ cell $/ element (n_ "v") &/ content >=> extractCellValue sst t
          f = listToMaybe $ cell $/ element (n_ "f") >=> fromCursor
          (r, c) = fromSingleCellRefNoting ref
          comment = commentsMap >>= lookupComment ref
        return (r, c, Cell s d comment f)
      collect = foldr collectRow (M.empty, M.empty)
      collectRow (_, Nothing, rowCells) (rowMap, cellMap) =
        (rowMap, foldr collectCell cellMap rowCells)
      collectRow (r, Just h, rowCells) (rowMap, cellMap) =
        (M.insert r h rowMap, foldr collectCell cellMap rowCells)
      collectCell (x, y, cd) = M.insert (x,y) cd

      commentCells =
        M.fromList
          [ (fromSingleCellRefNoting r, def {_cellComment = Just cmnt})
          | (r, cmnt) <- maybe [] CommentTable.toList commentsMap
          ]
      cells = cells0 `M.union` commentCells

      mProtection = listToMaybe $ cur $/ element (n_ "sheetProtection") >=> fromCursor

      mDrawingId = listToMaybe $ cur $/ element (n_ "drawing") >=> fromAttribute (odr"id")

      merges = cur $/ parseMerges
      parseMerges :: Cursor -> [Range]
      parseMerges = element (n_ "mergeCells") &/ element (n_ "mergeCell") >=> fromAttribute "ref"

      condFormtattings = M.fromList . map unCfPair  $ cur $/ element (n_ "conditionalFormatting") >=> fromCursor

      validations = M.fromList . map unDvPair $
          cur $/ element (n_ "dataValidations") &/ element (n_ "dataValidation") >=> fromCursor

      tableIds =
        cur $/ element (n_ "tableParts") &/ element (n_ "tablePart") >=>
        fromAttribute (odr "id")

  let mAutoFilter = listToMaybe $ cur $/ element (n_ "autoFilter") >=> fromCursor

  mDrawing <- case mDrawingId of
      Just dId -> do
          rel <- note (InvalidRef filePath dId) $ Relationships.lookup dId sheetRels
          Just <$> getDrawing ar contentTypes (relTarget rel)
      Nothing  ->
          return Nothing

  let ptType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/pivotTable"
  pTables <- forM (allByType ptType sheetRels) $ \rel -> do
    let ptPath = relTarget rel
    bs <- note (MissingFile ptPath) $ Zip.fromEntry <$> Zip.findEntryByPath ptPath ar
    note (InconsistentXlsx $ "Bad pivot table in " <> T.pack ptPath) $
      parsePivotTable (flip Prelude.lookup caches) bs

  tables <- forM tableIds $ \rId -> do
    fp <- lookupRelPath filePath sheetRels rId
    getTable ar fp

  return $
    Worksheet
      cws
      rowProps
      cells
      mDrawing
      merges
      sheetViews
      pageSetup
      condFormtattings
      validations
      pTables
      mAutoFilter
      tables
      mProtection

extractCellValue :: SharedStringTable -> Text -> Text -> [CellValue]
extractCellValue sst "s" v =
    case T.decimal v of
      Right (d, _) ->
        case sstItem sst d of
          XlsxText     txt  -> [CellText txt]
          XlsxRichText rich -> [CellRich rich]
      _ ->
        []
extractCellValue _ "str" str = [CellText str]
extractCellValue _ "n" v =
    case T.rational v of
      Right (d, _) -> [CellDouble d]
      _            -> []
extractCellValue _ "b" "1" = [CellBool True]
extractCellValue _ "b" "0" = [CellBool False]
extractCellValue _ _ _ = []

-- | Get xml cursor from the specified file inside the zip archive.
xmlCursorOptional :: Zip.Archive -> FilePath -> Parser (Maybe Cursor)
xmlCursorOptional ar fname =
    (Just <$> xmlCursorRequired ar fname) `catchError` missingToNothing
  where
    missingToNothing :: ParseError -> Either ParseError (Maybe a)
    missingToNothing (MissingFile _) = return Nothing
    missingToNothing other           = throwError other

-- | Get xml cursor from the given file, failing with MissingFile if not found.
xmlCursorRequired :: Zip.Archive -> FilePath -> Parser Cursor
xmlCursorRequired ar fname = do
    entry <- note (MissingFile fname) $ Zip.findEntryByPath fname ar
    cur <- left (\_ -> InvalidFile fname) $ parseLBS def (Zip.fromEntry entry)
    return $ fromDocument cur

-- | Get shared string table
getSharedStrings  :: Zip.Archive -> Parser SharedStringTable
getSharedStrings x = maybe sstEmpty (head . fromCursor) <$>
                     xmlCursorOptional x "xl/sharedStrings.xml"

getContentTypes :: Zip.Archive -> Parser ContentTypes
getContentTypes x = head . fromCursor <$> xmlCursorRequired x "[Content_Types].xml"

getStyles :: Zip.Archive -> Styles
getStyles ar = case Zip.fromEntry <$> Zip.findEntryByPath "xl/styles.xml" ar of
  Nothing  -> Styles L.empty
  Just xml -> Styles xml

getComments :: Zip.Archive -> Maybe FilePath -> FilePath -> Parser (Maybe CommentTable)
getComments ar drp fp = do
    mCurComments <- xmlCursorOptional ar fp
    mCurDr <- maybe (return Nothing) (xmlCursorOptional ar) drp
    return (liftA2 hide (hidden <$> mCurDr) . listToMaybe . fromCursor =<< mCurComments)
  where
    hide refs (CommentTable m) = CommentTable $ foldl' hideComment m refs
    hideComment m r = M.adjust (\c->c{_commentVisible = False}) r m
    v nm = Name nm (Just "urn:schemas-microsoft-com:vml") Nothing
    x nm = Name nm (Just "urn:schemas-microsoft-com:office:excel") Nothing
    hidden :: Cursor -> [CellRef]
    hidden cur = cur $/ checkElement visibleShape &/
                 element (x"ClientData") >=> shapeCellRef
    visibleShape Element{..} = elementName ==  (v"shape") &&
        maybe False (any ("visibility:hidden"==) . T.split (==';')) (M.lookup "style" elementAttributes)
    shapeCellRef :: Cursor -> [CellRef]
    shapeCellRef c = do
        r0 <- c $/ element (x"Row") &/ content >=> decimal
        c0 <- c $/ element (x"Column") &/ content >=> decimal
        return $ singleCellRef (r0 + 1, c0 + 1)

getCustomProperties :: Zip.Archive -> Parser CustomProperties
getCustomProperties ar = maybe CustomProperties.empty (head . fromCursor) <$> xmlCursorOptional ar "docProps/custom.xml"

getDrawing :: Zip.Archive -> ContentTypes ->  FilePath -> Parser Drawing
getDrawing ar contentTypes fp = do
    cur <- xmlCursorRequired ar fp
    drawingRels <- getRels ar fp
    unresolved <- headErr (InvalidFile fp) (fromCursor cur)
    anchors <- forM (unresolved ^. xdrAnchors) $ resolveFileInfo drawingRels
    return $ Drawing anchors
  where
    resolveFileInfo :: Relationships -> Anchor RefId RefId -> Parser (Anchor FileInfo ChartSpace)
    resolveFileInfo rels uAnch =
      case uAnch ^. anchObject of
        Picture {..} -> do
          let mRefId = _picBlipFill ^. bfpImageInfo
          mFI <- lookupFI rels mRefId
          let pic' =
                Picture
                { _picMacro = _picMacro
                , _picPublished = _picPublished
                , _picNonVisual = _picNonVisual
                , _picBlipFill = (_picBlipFill & bfpImageInfo .~ mFI)
                , _picShapeProperties = _picShapeProperties
                }
          return uAnch {_anchObject = pic'}
        Graphic nv rId tr -> do
          chartPath <- lookupRelPath fp rels rId
          chart <- readChart ar chartPath
          return uAnch {_anchObject = Graphic nv chart tr}
    lookupFI _ Nothing = return Nothing
    lookupFI rels (Just rId) = do
        path <- lookupRelPath fp rels rId
        -- content types use paths starting with /
        contentType <- note (InvalidFile path) $ ContentTypes.lookup ("/" <> path) contentTypes
        contents <- Zip.fromEntry <$> note (MissingFile path) (Zip.findEntryByPath path ar)
        return . Just $ FileInfo (stripMediaPrefix path) contentType contents
    stripMediaPrefix :: FilePath -> FilePath
    stripMediaPrefix p = fromMaybe p $ stripPrefix "xl/media/" p

readChart :: Zip.Archive -> FilePath -> Parser ChartSpace
readChart ar path = head . fromCursor <$> xmlCursorRequired ar path

-- | readWorkbook pulls the names of the sheets and the defined names
readWorkbook :: Zip.Archive -> Parser ([WorksheetFile], DefinedNames, Caches)
readWorkbook ar = do
  let wbPath = "xl/workbook.xml"
  cur <- xmlCursorRequired ar wbPath
  wbRels <- getRels ar wbPath
  -- Specification says the 'name' is required.
  let mkDefinedName :: Cursor -> [(Text, Maybe Text, Text)]
      mkDefinedName c =
        return
          ( head $ attribute "name" c
          , listToMaybe $ attribute "localSheetId" c
          , T.concat $ c $/ content)
      names =
        cur $/ element (n_ "definedNames") &/ element (n_ "definedName") >=>
        mkDefinedName
  sheets <-
    sequence $
    cur $/ element (n_ "sheets") &/ element (n_ "sheet") >=>
    liftA2 (worksheetFile wbPath wbRels) <$> attribute "name" <*>
    fromAttribute (odr "id")
  let cacheRefs =
        cur $/ element (n_ "pivotCaches") &/ element (n_ "pivotCache") >=>
        liftA2 (,) <$> fromAttribute "cacheId" <*> fromAttribute (odr "id")
  caches <-
    forM cacheRefs $ \(cacheId, rId) -> do
      path <- lookupRelPath wbPath wbRels rId
      bs <-
        note (MissingFile path) $ Zip.fromEntry <$> Zip.findEntryByPath path ar
      sources <-
        note (InconsistentXlsx $ "Bad pivot table cache in " <> T.pack path) $
        parseCache bs
      return (cacheId, sources)
  return (sheets, DefinedNames names, caches)

getTable :: Zip.Archive -> FilePath -> Parser Table
getTable ar fp = do
  cur <- xmlCursorRequired ar fp
  headErr (InvalidFile fp) (fromCursor cur)

worksheetFile :: FilePath -> Relationships -> Text -> RefId -> Parser WorksheetFile
worksheetFile parentPath wbRels name rId =
  WorksheetFile name <$> lookupRelPath parentPath wbRels rId

getRels :: Zip.Archive -> FilePath -> Parser Relationships
getRels ar fp = do
    let (dir, file) = splitFileName fp
        relsPath = dir </> "_rels" </> file <.> "rels"
    c <- xmlCursorOptional ar relsPath
    return $ maybe Relationships.empty (setTargetsFrom fp . head . fromCursor) c

lookupRelPath :: FilePath
              -> Relationships
              -> RefId
              -> Either ParseError FilePath
lookupRelPath fp rels rId =
  relTarget <$> note (InvalidRef fp rId) (Relationships.lookup rId rels)
