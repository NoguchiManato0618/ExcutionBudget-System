/* ============================================================================
   メーカー特価マスタ（tbl_tori_ManufacturerSpecialPrice）複製スクリプト
                                                       （Microsoft SQL Server）

   目的 : [ExecutionBudgetDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] の
          全行を、下記 5 つの DB の同名テーブルへコピーする。

            NEW00000001NEWDB
            NEW00000002NEWDB
            NEW00000015NEWDB
            NEW00000017NEWDB
            NEW00000020NEWDB

   方式 : ★ 追加のみ（既存データは一切変更しない）★
          ・コピー先に「同じ品目」が既に有る行は INSERT しない（スキップ）
          ・コピー先にしか無い行はそのまま残す
          ・UPDATE / DELETE は行わない

   前提 : 5 つの DB はすべて同一インスタンス（WIN-9L8J6004KJ5\SQLEXPRESS）上に
          あり、3 部分名（[DB].[dbo].[表]）で参照できること。
          別インスタンスの場合はこのスクリプトは使えない（リンクサーバー、
          または SSMS のインポート／エクスポート ウィザードを使う）。

   ---------------------------------------------------------------------------
   ★ 「同じ品目」の判定（重複キー）★

     MSP_Property, MSP_Supplise, MSP_AuxiliaryMaterials,
     MSP_Maker, MSP_Series, MSP_ProductName, MSP_ProductNumber

     の 7 列がすべて一致する行を「同じ品目」とみなす。

     突合に使わない列とその理由

     ・ik               … ★IDENTITY（DB ごとの採番）。コピー元とコピー先で
                           必ず値が違うため、キーに入れると重複が永久に
                           検出されず、実行のたびに二重登録されてしまう。
     ・MSP_No           … 同上。DB ごとの採番のため使わない。
     ・MSP_UnitPrice    ─┐ 同じ品目で単価・掛率だけが違う場合は
     ・MSP_PurchaseRate ─┘ 「既にある」と判断してスキップする（＝上書きしない）
                           差異は STEP 3-2 で一覧できる。

     判定は NULL 同士も一致とみなす（INTERSECT による NULL セーフ比較）。
     キーを変えたい場合は、各 STEP の INTERSECT の列並びを揃えて書き換える。
     ただし IDENTITY 列（ik）は絶対に入れないこと。

   ---------------------------------------------------------------------------
   ★ IDENTITY 列と MSP_No の扱い ★

     INSERT する列は、実行時にコピー先の sys.columns を読んで組み立てる。
     列名を決め打ちしないため、コピー先ごとに構成が違っても動く。

       ・コピー先が IDENTITY の列 → INSERT 対象から外し、コピー先で採番させる
                                    （値を指定するとエラー 544 になるため）
       ・両方にある非 IDENTITY 列 → コピー元の値をそのままコピー
       ・コピー先にしか無い列     → 触らない（既定値／NULL のまま）
       ・コピー元にしか無い列     → コピーされない

     MSP_No が IDENTITY でない数値型の場合だけ、
     コピー先の MAX(MSP_No) + 連番で採番して入れる。
     MSP_No が無い／数値でない DB はスキップし、メッセージを出す。

     ★ どの列が IDENTITY かは STEP 1-3 で必ず確認すること。
       MSP_No 以外（ik など）が IDENTITY だった場合、その列の値は
       コピー元から引き継がれず再採番される。業務上問題ないか確認する。

   ---------------------------------------------------------------------------
   ---------------------------------------------------------------------------
   ★★★ 実行方法（重要）★★★

     STEP 0 → 1 → 2 → 3 → 4 → 5 の順に、
     ブロックを 1 つずつマウスで選択し、[F5] で実行する。
     ★ ファイル全体を選択して実行してはいけない ★

     理由: STEP 6 は「STEP 4 で入れた行を消す」取り消し処理のため、
           全体を流すと投入した内容がその場で削除されてしまう。
           （そのため STEP 6-2 は既定でコメントアウトしてある）

     STEP 6 は問題があったときだけ、STEP 7 は業務確認が終わってから実行する。

     ※ 全体を流してしまい「データが入っていない」場合は、
        STEP 4 → STEP 5 だけを選択して実行し直せばよい。
        STEP 4 は「コピー先に無い品目だけ」を入れるため、
        何度実行しても二重登録にはならない。
   ============================================================================ */


/* ============================================================================
   STEP 0-1 : 作業前の確認
   ---------------------------------------------------------------------------
   コピー先 DB に接続中の利用者がいないことを確認する。
   件数が出た DB は、利用者に停止を依頼してから進める。
   ============================================================================ */
SELECT DB_NAME(s.database_id) AS db_name,
       s.session_id, s.login_name, s.host_name, s.program_name
  FROM sys.dm_exec_sessions AS s
 WHERE s.is_user_process = 1
   AND DB_NAME(s.database_id) IN ('NEW00000001NEWDB','NEW00000002NEWDB',
                                  'NEW00000015NEWDB','NEW00000017NEWDB',
                                  'NEW00000020NEWDB')
 ORDER BY db_name, s.session_id;
GO


/* ============================================================================
   STEP 0-2 : バックアップを取得する（★必須・切り戻しの唯一の手段）
   ---------------------------------------------------------------------------
   ・出力先 C:\dbdiff は事前に作成しておく
   ・SQL Server Express は WITH COMPRESSION が使えないため付けないこと
   ============================================================================ */
BACKUP DATABASE [NEW00000001NEWDB] TO DISK = N'C:\dbdiff\NEW00000001NEWDB_before_20260907.bak' WITH INIT, STATS = 10;
BACKUP DATABASE [NEW00000002NEWDB] TO DISK = N'C:\dbdiff\NEW00000002NEWDB_before_20260907.bak' WITH INIT, STATS = 10;
BACKUP DATABASE [NEW00000015NEWDB] TO DISK = N'C:\dbdiff\NEW00000015NEWDB_before_20260907.bak' WITH INIT, STATS = 10;
BACKUP DATABASE [NEW00000017NEWDB] TO DISK = N'C:\dbdiff\NEW00000017NEWDB_before_20260907.bak' WITH INIT, STATS = 10;
BACKUP DATABASE [NEW00000020NEWDB] TO DISK = N'C:\dbdiff\NEW00000020NEWDB_before_20260907.bak' WITH INIT, STATS = 10;
GO


/* ============================================================================
   STEP 1-1 : コピー先 5 DB の存在とテーブルの有無を確認する
   ---------------------------------------------------------------------------
   ・db_exists  = 1 … DB がある
   ・tbl_exists = 1 … tbl_tori_ManufacturerSpecialPrice がある
   → 0 の DB があれば、対象から外すか、先に構造更新（更新手順.md）を実施する
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @dbs TABLE (db sysname PRIMARY KEY);
INSERT INTO @dbs (db) VALUES
    ('NEW00000001NEWDB'),
    ('NEW00000002NEWDB'),
    ('NEW00000015NEWDB'),
    ('NEW00000017NEWDB'),
    ('NEW00000020NEWDB');

SELECT d.db                                             AS コピー先DB,
       CASE WHEN DB_ID(d.db) IS NULL THEN 0 ELSE 1 END  AS db_exists,
       CASE WHEN OBJECT_ID(QUOTENAME(d.db)
                         + N'.[dbo].[tbl_tori_ManufacturerSpecialPrice]',
                           'U') IS NULL THEN 0 ELSE 1 END AS tbl_exists
  FROM @dbs AS d
 ORDER BY d.db;
GO


/* ============================================================================
   STEP 1-2 : 列構成・MSP_No の型・IDENTITY 有無を突き合わせる（★重要）
   ---------------------------------------------------------------------------
   1 つ目の結果セット … 列構成の差分（正 = ExecutionBudgetDB）
       diff 欄に「コピー先に列が無い」「型が違う」等が出た DB は、
       先に構造更新（更新手順.md）を実施してから STEP 4 に進む。
   2 つ目の結果セット … MSP_No の型と IDENTITY 有無（STEP 4 の採番方法が決まる）
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @sql nvarchar(max) = N'';

;WITH t(db) AS (
    SELECT 'ExecutionBudgetDB' UNION ALL SELECT 'NEW00000001NEWDB'
    UNION ALL SELECT 'NEW00000002NEWDB' UNION ALL SELECT 'NEW00000015NEWDB'
    UNION ALL SELECT 'NEW00000017NEWDB' UNION ALL SELECT 'NEW00000020NEWDB'
)
SELECT @sql = @sql + N'
SELECT ' + QUOTENAME(db, '''') + N' AS db_name, c.name AS col_name, c.column_id,
       TYPE_NAME(c.user_type_id) AS type_name, c.max_length, c.precision, c.scale,
       c.is_nullable, c.is_identity
  FROM ' + QUOTENAME(db) + N'.sys.columns AS c
 WHERE c.object_id = OBJECT_ID(' + QUOTENAME(db + N'.dbo.tbl_tori_ManufacturerSpecialPrice', '''') + N')
UNION ALL'
  FROM t
 WHERE OBJECT_ID(QUOTENAME(db) + N'.[dbo].[tbl_tori_ManufacturerSpecialPrice]', 'U') IS NOT NULL;

IF @sql = N''
BEGIN
    RAISERROR (N'対象テーブルが 1 つも見つかりません。STEP 1-1 を確認してください。', 16, 1);
    RETURN;
END

/* 末尾の UNION ALL を落として一時表へ */
SET @sql = N'SELECT * INTO #cols FROM ('
         + LEFT(@sql, LEN(@sql) - LEN(N'UNION ALL'))
         + N') AS x;

/* --- 列構成の突合（正 = ExecutionBudgetDB） ---
   コピー先 DB × 全列名 のマス目を作ってから、両側を突き合わせる。
   （こうしないと「コピー先に列が無い」行の DB 名が分からなくなる）            */
SELECT d.db_name                                       AS コピー先DB,
       n.col_name                                      AS col_name,
       s.type_name AS src_type, t.type_name AS tgt_type,
       s.max_length AS src_len, t.max_length AS tgt_len,
       t.is_identity                                   AS tgt_is_identity,
       CASE WHEN t.col_name IS NULL           THEN N''*** コピー先に列が無い ***''
            WHEN s.col_name IS NULL           THEN N''コピー先のみに存在（影響なし）''
            WHEN s.type_name  <> t.type_name  THEN N''型が違う''
            WHEN s.max_length <> t.max_length THEN N''桁が違う''
            WHEN s.precision  <> t.precision
              OR s.scale      <> t.scale      THEN N''精度が違う''
            WHEN s.is_nullable <> t.is_nullable THEN N''NULL 可否が違う''
            ELSE N'''' END                             AS diff
  FROM (SELECT DISTINCT db_name FROM #cols WHERE db_name <> N''ExecutionBudgetDB'') AS d
 CROSS JOIN (SELECT col_name, MIN(column_id) AS column_id FROM #cols GROUP BY col_name) AS n
  LEFT JOIN #cols AS s ON s.db_name =  N''ExecutionBudgetDB'' AND s.col_name = n.col_name
  LEFT JOIN #cols AS t ON t.db_name =  d.db_name             AND t.col_name = n.col_name
 WHERE s.col_name IS NOT NULL OR t.col_name IS NOT NULL
 ORDER BY d.db_name, n.column_id;

/* --- MSP_No の型と IDENTITY 有無（STEP 4 の分岐に使う） --- */
SELECT db_name AS DB名, type_name AS MSP_Noの型, is_identity AS IDENTITYか
  FROM #cols
 WHERE col_name = N''MSP_No''
 ORDER BY CASE WHEN db_name = N''ExecutionBudgetDB'' THEN 0 ELSE 1 END, db_name;

DROP TABLE #cols;';

EXEC sys.sp_executesql @sql;
GO


/* ============================================================================
   STEP 1-3 : IDENTITY 列を洗い出す（★STEP 4 の動作を決める）
   ---------------------------------------------------------------------------
   コピー先の IDENTITY 列には値を指定して INSERT できない
   （エラー 544: IDENTITY_INSERT が OFF に設定されているときは…）。
   STEP 4 は、ここに出た列を自動的に INSERT 対象から外し、
   コピー先の採番に任せる。

   ★ MSP_No 以外の列（ik など）が IDENTITY だった場合、その列の値は
     コピー元から引き継がれず、コピー先で採番し直される。
     業務上それで問題ないかを必ず確認すること。
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @sql nvarchar(max) = N'';

;WITH t(db) AS (
    SELECT 'ExecutionBudgetDB' UNION ALL SELECT 'NEW00000001NEWDB'
    UNION ALL SELECT 'NEW00000002NEWDB' UNION ALL SELECT 'NEW00000015NEWDB'
    UNION ALL SELECT 'NEW00000017NEWDB' UNION ALL SELECT 'NEW00000020NEWDB'
)
SELECT @sql = @sql + N'
SELECT ' + QUOTENAME(db, '''') + N' AS DB名, c.name AS IDENTITY列,
       TYPE_NAME(c.user_type_id) AS 型, c.column_id AS 列位置
  FROM ' + QUOTENAME(db) + N'.sys.columns AS c
 WHERE c.object_id = OBJECT_ID(' + QUOTENAME(db + N'.dbo.tbl_tori_ManufacturerSpecialPrice', '''') + N')
   AND c.is_identity = 1
UNION ALL'
  FROM t
 WHERE OBJECT_ID(QUOTENAME(db) + N'.[dbo].[tbl_tori_ManufacturerSpecialPrice]', 'U') IS NOT NULL;

SET @sql = LEFT(@sql, LEN(@sql) - LEN(N'UNION ALL')) + N' ORDER BY DB名, 列位置;';
EXEC sys.sp_executesql @sql;
GO


/* ============================================================================
   STEP 2 : 作業用の記録テーブルを作る（切り戻しに使う）
   ---------------------------------------------------------------------------
   投入前の MAX(MSP_No) を DB ごとに記録しておく。
   STEP 6 で「この値より大きい MSP_No」＝今回入れた行、として取り消せる。

   ※ 作業がすべて終わったら STEP 7 で削除する。
   ============================================================================ */
USE [ExecutionBudgetDB];
GO

IF OBJECT_ID(N'dbo.tbl_work_MSP_Copy_20260907', 'U') IS NOT NULL
    DROP TABLE dbo.tbl_work_MSP_Copy_20260907;
GO

CREATE TABLE dbo.tbl_work_MSP_Copy_20260907 (
    db_name        sysname       NOT NULL PRIMARY KEY,
    max_no_before  bigint        NULL,   -- 投入前の MAX(MSP_No)
    rows_before    int           NULL,   -- 投入前の行数
    rows_inserted  int           NULL,   -- 実際に入れた件数（STEP 4 で更新）
    executed_at    datetime2(0)  NULL
);
GO


/* ============================================================================
   STEP 3-1 : 投入予定件数を事前に確認する（★まだ投入しない）
   ---------------------------------------------------------------------------
   ・コピー元件数   … ExecutionBudgetDB の全行数
   ・現在の件数     … コピー先の現在の行数
   ・投入予定件数   … 今回 INSERT される件数（コピー先に無い品目）
   ・重複スキップ件数 … 既に同じ品目があるため入れない件数

     コピー元件数 = 投入予定件数 + 重複スキップ件数 になることを確認する。
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @db sysname, @sql nvarchar(max);

IF OBJECT_ID('tempdb..#plan') IS NOT NULL DROP TABLE #plan;
CREATE TABLE #plan (db_name sysname, source_rows int, target_rows int,
                    to_insert int, skip_dup int);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT db FROM (VALUES ('NEW00000001NEWDB'),('NEW00000002NEWDB'),
                           ('NEW00000015NEWDB'),('NEW00000017NEWDB'),
                           ('NEW00000020NEWDB')) AS v(db);
OPEN cur;
FETCH NEXT FROM cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(QUOTENAME(@db) + N'.[dbo].[tbl_tori_ManufacturerSpecialPrice]', 'U') IS NOT NULL
    BEGIN
        SET @sql = N'
        INSERT INTO #plan (db_name, source_rows, target_rows, to_insert, skip_dup)
        SELECT @p_db,
               (SELECT COUNT(*) FROM [ExecutionBudgetDB].[dbo].[tbl_tori_ManufacturerSpecialPrice]),
               (SELECT COUNT(*) FROM ' + QUOTENAME(@db) + N'.[dbo].[tbl_tori_ManufacturerSpecialPrice]),
               (SELECT COUNT(*)
                  FROM [ExecutionBudgetDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] AS s
                 WHERE NOT EXISTS (
                       SELECT 1
                         FROM ' + QUOTENAME(@db) + N'.[dbo].[tbl_tori_ManufacturerSpecialPrice] AS t
                        WHERE EXISTS (
                              SELECT s.MSP_Property, s.MSP_Supplise, s.MSP_AuxiliaryMaterials,
                                     s.MSP_Maker, s.MSP_Series, s.MSP_ProductName,
                                     s.MSP_ProductNumber
                              INTERSECT
                              SELECT t.MSP_Property, t.MSP_Supplise, t.MSP_AuxiliaryMaterials,
                                     t.MSP_Maker, t.MSP_Series, t.MSP_ProductName,
                                     t.MSP_ProductNumber))),
               (SELECT COUNT(*)
                  FROM [ExecutionBudgetDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] AS s
                 WHERE EXISTS (
                       SELECT 1
                         FROM ' + QUOTENAME(@db) + N'.[dbo].[tbl_tori_ManufacturerSpecialPrice] AS t
                        WHERE EXISTS (
                              SELECT s.MSP_Property, s.MSP_Supplise, s.MSP_AuxiliaryMaterials,
                                     s.MSP_Maker, s.MSP_Series, s.MSP_ProductName,
                                     s.MSP_ProductNumber
                              INTERSECT
                              SELECT t.MSP_Property, t.MSP_Supplise, t.MSP_AuxiliaryMaterials,
                                     t.MSP_Maker, t.MSP_Series, t.MSP_ProductName,
                                     t.MSP_ProductNumber)));';
        EXEC sys.sp_executesql @sql, N'@p_db sysname', @p_db = @db;
    END
    ELSE
        INSERT INTO #plan (db_name) VALUES (@db);   -- テーブルが無い DB

    FETCH NEXT FROM cur INTO @db;
END
CLOSE cur; DEALLOCATE cur;

SELECT db_name AS コピー先DB, source_rows AS コピー元件数, target_rows AS 現在の件数,
       to_insert AS 投入予定件数, skip_dup AS 重複スキップ件数
  FROM #plan
 ORDER BY db_name;

DROP TABLE #plan;
GO


/* ============================================================================
   STEP 3-2 : 単価・掛率だけが違う品目を一覧する（参考）
   ---------------------------------------------------------------------------
   同じ品目がコピー先に既にあり、単価または掛率が異なるもの。
   この方式（追加のみ）では上書きしないため、ここに出た行はコピー先の値のまま残る。
   コピー元の値に揃えたい場合は、この一覧を見て個別に判断すること。

   ▼ DB 名（2 か所）を書き換えて 5 DB 分実行する（既定は NEW00000001NEWDB）
   ============================================================================ */
SELECT s.MSP_Maker, s.MSP_Series, s.MSP_ProductName, s.MSP_ProductNumber,
       s.MSP_UnitPrice    AS 元_単価, t.MSP_UnitPrice    AS 先_単価,
       s.MSP_PurchaseRate AS 元_掛率, t.MSP_PurchaseRate AS 先_掛率
  FROM [ExecutionBudgetDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] AS s
  JOIN [NEW00000001NEWDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] AS t
    ON EXISTS (SELECT s.MSP_Property, s.MSP_Supplise, s.MSP_AuxiliaryMaterials,
                      s.MSP_Maker, s.MSP_Series, s.MSP_ProductName,
                      s.MSP_ProductNumber
               INTERSECT
               SELECT t.MSP_Property, t.MSP_Supplise, t.MSP_AuxiliaryMaterials,
                      t.MSP_Maker, t.MSP_Series, t.MSP_ProductName,
                      t.MSP_ProductNumber)
 WHERE NOT EXISTS (SELECT s.MSP_UnitPrice, s.MSP_PurchaseRate
                   INTERSECT
                   SELECT t.MSP_UnitPrice, t.MSP_PurchaseRate)
 ORDER BY s.MSP_Maker, s.MSP_Series, s.MSP_ProductName;
GO


/* ============================================================================
   STEP 4 : データを投入する（★本番）
   ---------------------------------------------------------------------------
   ・DB ごとにトランザクションを張る。1 つ失敗しても他の DB には影響しない
   ・投入前の MAX(MSP_No) / 行数を STEP 2 の作業表に記録する
   ・INSERT する列は、実行時にコピー先の sys.columns から組み立てる
       - コピー先が IDENTITY の列は自動的に除外（エラー 544 の回避）
       - 両方にある非 IDENTITY 列だけをコピー
       - MSP_No が非 IDENTITY の数値型なら MAX + 連番で採番
   ・何度実行しても、コピー先に無い品目だけを入れるので二重登録にならない
   ・実行後は［メッセージ］タブで DB ごとの結果を確認する
       IDENTITY 列（値は引き継がず、コピー先で採番）: ...
       投入件数: NNN 件（投入前 MMM 件）...
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @db sysname, @sql nvarchar(max), @obj nvarchar(400), @objid int,
        @colList nvarchar(max), @selList nvarchar(max), @idCols nvarchar(max),
        @noIsIdentity bit, @noType sysname, @genNo bit,
        @inserted int, @maxNo bigint, @rowsBefore int;

/* --- コピー元の列一覧（固定） --- */
IF OBJECT_ID('tempdb..#scols') IS NOT NULL DROP TABLE #scols;
CREATE TABLE #scols (name sysname PRIMARY KEY);
INSERT INTO #scols (name)
SELECT c.name
  FROM [ExecutionBudgetDB].sys.columns AS c
 WHERE c.object_id = OBJECT_ID(N'[ExecutionBudgetDB].[dbo].[tbl_tori_ManufacturerSpecialPrice]', 'U');

/* --- コピー先の列一覧（DB ごとに入れ替える） --- */
IF OBJECT_ID('tempdb..#tcols') IS NOT NULL DROP TABLE #tcols;
CREATE TABLE #tcols (name sysname, is_identity bit, type_name sysname, column_id int);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT db FROM (VALUES ('NEW00000001NEWDB'),('NEW00000002NEWDB'),
                           ('NEW00000015NEWDB'),('NEW00000017NEWDB'),
                           ('NEW00000020NEWDB')) AS v(db);
OPEN cur;
FETCH NEXT FROM cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT N'---------- ' + @db + N' ----------';

    SET @obj   = QUOTENAME(@db) + N'.[dbo].[tbl_tori_ManufacturerSpecialPrice]';
    SET @objid = OBJECT_ID(@obj, 'U');

    IF @objid IS NULL
    BEGIN
        PRINT N'  スキップ: テーブルがありません（または参照権限がありません）';
        FETCH NEXT FROM cur INTO @db;
        CONTINUE;
    END

    /* --- コピー先の列構成と IDENTITY を取得（★決め打ちしない） --- */
    TRUNCATE TABLE #tcols;
    SET @sql = N'SELECT c.name, c.is_identity, TYPE_NAME(c.user_type_id), c.column_id
                   FROM ' + QUOTENAME(@db) + N'.sys.columns AS c
                  WHERE c.object_id = @p_objid;';
    INSERT INTO #tcols (name, is_identity, type_name, column_id)
    EXEC sys.sp_executesql @sql, N'@p_objid int', @p_objid = @objid;

    IF NOT EXISTS (SELECT 1 FROM #tcols WHERE name = N'MSP_No')
    BEGIN
        PRINT N'  スキップ: MSP_No 列がありません（または列情報を取得できません）';
        FETCH NEXT FROM cur INTO @db;
        CONTINUE;
    END

    SELECT @noIsIdentity = is_identity, @noType = type_name
      FROM #tcols WHERE name = N'MSP_No';

    /* MSP_No が IDENTITY でない場合だけ、こちらで採番して入れる */
    SET @genNo = CASE WHEN @noIsIdentity = 1 THEN 0 ELSE 1 END;

    IF @genNo = 1 AND @noType NOT IN ('int','bigint','smallint','tinyint','numeric','decimal')
    BEGIN
        PRINT N'  スキップ: MSP_No が IDENTITY でなく、型 ' + @noType + N' は自動採番できません';
        FETCH NEXT FROM cur INTO @db;
        CONTINUE;
    END

    /* --- INSERT する列を組み立てる -------------------------------------------
       条件: コピー元とコピー先の両方にあり、かつコピー先が IDENTITY でない列。
             IDENTITY 列は値を指定できない（エラー 544）ため必ず外す。
       ---------------------------------------------------------------------- */
    SET @colList = NULL;
    SET @selList = NULL;
    SET @idCols  = NULL;

    SELECT @colList = STUFF((SELECT N',' + QUOTENAME(t.name)
                               FROM #tcols AS t
                              WHERE t.is_identity = 0
                                AND EXISTS (SELECT 1 FROM #scols AS s WHERE s.name = t.name)
                              ORDER BY t.column_id
                                FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 1, N'');

    SELECT @selList = STUFF((SELECT N',' + CASE WHEN t.name = N'MSP_No' AND @genNo = 1
                                                THEN N'(@p_max + ROW_NUMBER() OVER (ORDER BY s.[MSP_No]))'
                                                ELSE N's.' + QUOTENAME(t.name) END
                               FROM #tcols AS t
                              WHERE t.is_identity = 0
                                AND EXISTS (SELECT 1 FROM #scols AS s WHERE s.name = t.name)
                              ORDER BY t.column_id
                                FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 1, N'');

    SELECT @idCols = STUFF((SELECT N', ' + t.name
                              FROM #tcols AS t
                             WHERE t.is_identity = 1
                             ORDER BY t.column_id
                               FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

    IF @colList IS NULL
    BEGIN
        PRINT N'  スキップ: コピーできる列がありません';
        FETCH NEXT FROM cur INTO @db;
        CONTINUE;
    END

    PRINT N'  IDENTITY 列（値は引き継がず、コピー先で採番）: ' + ISNULL(@idCols, N'なし');

    /* --- 投入前の状態を記録 --- */
    SET @sql = N'SELECT @p_max = MAX(CONVERT(bigint, MSP_No)), @p_rows = COUNT(*)
                   FROM ' + @obj + N';';
    EXEC sys.sp_executesql @sql, N'@p_max bigint OUTPUT, @p_rows int OUTPUT',
                           @p_max = @maxNo OUTPUT, @p_rows = @rowsBefore OUTPUT;
    SET @maxNo = ISNULL(@maxNo, 0);

    DELETE FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907 WHERE db_name = @db;
    INSERT INTO [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907
                (db_name, max_no_before, rows_before, rows_inserted, executed_at)
         VALUES (@db, @maxNo, @rowsBefore, NULL, SYSDATETIME());

    /* --- 投入本体（コピー先に無い品目のみ） --- */
    SET @sql = N'
    BEGIN TRANSACTION;
    INSERT INTO ' + @obj + N'
          (' + @colList + N')
    SELECT ' + @selList + N'
      FROM [ExecutionBudgetDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] AS s
     WHERE NOT EXISTS (
           SELECT 1
             FROM ' + @obj + N' AS t
            WHERE EXISTS (
                  SELECT s.MSP_Property, s.MSP_Supplise, s.MSP_AuxiliaryMaterials,
                         s.MSP_Maker, s.MSP_Series, s.MSP_ProductName,
                         s.MSP_ProductNumber
                  INTERSECT
                  SELECT t.MSP_Property, t.MSP_Supplise, t.MSP_AuxiliaryMaterials,
                         t.MSP_Maker, t.MSP_Series, t.MSP_ProductName,
                         t.MSP_ProductNumber));
    SET @p_ins = @@ROWCOUNT;
    COMMIT TRANSACTION;';

    EXEC sys.sp_executesql @sql,
         N'@p_max bigint, @p_ins int OUTPUT',
         @p_max = @maxNo, @p_ins = @inserted OUTPUT;

    UPDATE [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907
       SET rows_inserted = @inserted
     WHERE db_name = @db;

    PRINT N'  投入件数: ' + CONVERT(nvarchar(20), @inserted)
        + N' 件（投入前 ' + CONVERT(nvarchar(20), @rowsBefore) + N' 件）'
        + CASE WHEN @genNo = 1
               THEN N' / MSP_No は ' + CONVERT(nvarchar(20), @maxNo) + N' の次から採番'
               ELSE N' / MSP_No は IDENTITY で自動採番' END;

    FETCH NEXT FROM cur INTO @db;
END
CLOSE cur; DEALLOCATE cur;

DROP TABLE #scols;
DROP TABLE #tcols;

PRINT N'---------- 完了 ----------';
GO


/* ============================================================================
   STEP 5-1 : 投入結果を確認する（★最重要）
   ---------------------------------------------------------------------------
   ・投入後件数 = 投入前件数 + 投入件数 になっていること
   ・未投入件数 = 0（コピー元にあってコピー先に無い品目が残っていない）
   → 判定がすべて OK なら成功
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @db sysname, @sql nvarchar(max);

IF OBJECT_ID('tempdb..#chk') IS NOT NULL DROP TABLE #chk;
CREATE TABLE #chk (db_name sysname, rows_after int, still_missing int);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT db_name FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907;
OPEN cur;
FETCH NEXT FROM cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
    INSERT INTO #chk (db_name, rows_after, still_missing)
    SELECT @p_db,
           (SELECT COUNT(*) FROM ' + QUOTENAME(@db) + N'.[dbo].[tbl_tori_ManufacturerSpecialPrice]),
           (SELECT COUNT(*)
              FROM [ExecutionBudgetDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] AS s
             WHERE NOT EXISTS (
                   SELECT 1
                     FROM ' + QUOTENAME(@db) + N'.[dbo].[tbl_tori_ManufacturerSpecialPrice] AS t
                    WHERE EXISTS (
                          SELECT s.MSP_Property, s.MSP_Supplise, s.MSP_AuxiliaryMaterials,
                                 s.MSP_Maker, s.MSP_Series, s.MSP_ProductName,
                                 s.MSP_ProductNumber
                          INTERSECT
                          SELECT t.MSP_Property, t.MSP_Supplise, t.MSP_AuxiliaryMaterials,
                                 t.MSP_Maker, t.MSP_Series, t.MSP_ProductName,
                                 t.MSP_ProductNumber)));';
    EXEC sys.sp_executesql @sql, N'@p_db sysname', @p_db = @db;

    FETCH NEXT FROM cur INTO @db;
END
CLOSE cur; DEALLOCATE cur;

SELECT w.db_name       AS コピー先DB,
       w.rows_before   AS 投入前件数,
       w.rows_inserted AS 投入件数,
       c.rows_after    AS 投入後件数,
       c.still_missing AS 未投入件数,
       CASE WHEN c.rows_after = w.rows_before + ISNULL(w.rows_inserted, 0)
             AND c.still_missing = 0 THEN N'OK'
            ELSE N'★要確認' END AS 判定
  FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907 AS w
  LEFT JOIN #chk AS c ON c.db_name = w.db_name
 ORDER BY w.db_name;

DROP TABLE #chk;
GO


/* ============================================================================
   STEP 5-2 : 実際に入ったデータを目視で確認する（参考）
   ---------------------------------------------------------------------------
   ▼ DB 名（2 か所）を書き換えて実行する
   ============================================================================ */
SELECT TOP (100) *
  FROM [NEW00000001NEWDB].[dbo].[tbl_tori_ManufacturerSpecialPrice]
 WHERE CONVERT(bigint, MSP_No) >
       ISNULL((SELECT max_no_before FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907
                WHERE db_name = 'NEW00000001NEWDB'), 0)
 ORDER BY MSP_No;
GO


/* ============================================================================
   STEP 6 : 取り消し（問題があった場合のみ）★ 通常は実行しない ★
   ---------------------------------------------------------------------------
   ここは STEP 4 で入れた行を消す処理。投入を確定させたい場合は実行しないこと。

   今回の投入分だけを削除する。
   「投入前の MAX(MSP_No) より大きい行」＝今回入れた行、として判別する。

   ★ 先に必ず STEP 6-1 で件数を確認し、投入件数と一致することを見てから
      STEP 6-2 を実行する。
   ★ 一致しない場合（作業中に他の人が登録した等）は、この方法は使わずに
      STEP 0-2 のバックアップからリストアする（更新手順.md の「切り戻し手順」）。
   ============================================================================ */

/* --- STEP 6-1 : 削除対象の件数を確認する --- */
SET NOCOUNT ON;

DECLARE @db sysname, @sql nvarchar(max);

IF OBJECT_ID('tempdb..#undo') IS NOT NULL DROP TABLE #undo;
CREATE TABLE #undo (db_name sysname, delete_target int);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT db_name FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907;
OPEN cur;
FETCH NEXT FROM cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
    INSERT INTO #undo (db_name, delete_target)
    SELECT @p_db, COUNT(*)
      FROM ' + QUOTENAME(@db) + N'.[dbo].[tbl_tori_ManufacturerSpecialPrice]
     WHERE CONVERT(bigint, MSP_No) >
           ISNULL((SELECT max_no_before
                     FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907
                    WHERE db_name = @p_db), 0);';
    EXEC sys.sp_executesql @sql, N'@p_db sysname', @p_db = @db;
    FETCH NEXT FROM cur INTO @db;
END
CLOSE cur; DEALLOCATE cur;

SELECT w.db_name AS コピー先DB, w.rows_inserted AS 投入件数,
       u.delete_target AS 削除対象件数,
       CASE WHEN u.delete_target = w.rows_inserted THEN N'一致（削除してよい）'
            ELSE N'★不一致：バックアップからリストアすること' END AS 判定
  FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907 AS w
  LEFT JOIN #undo AS u ON u.db_name = w.db_name
 ORDER BY w.db_name;

DROP TABLE #undo;
GO

/* --- STEP 6-2 : 実際に削除する（STEP 6-1 がすべて「一致」の場合のみ） -------

   ★★★ 既定ではコメントアウトしてある。★★★
   ここは STEP 4 で入れた行をそのまま消す処理のため、うっかり全体実行すると
   投入した内容が消える。取り消すときだけ、必要な DB の行の
   コメント（先頭の -- ）を外して、その行を選択して実行すること。
   -------------------------------------------------------------------------- */

-- DELETE t FROM [NEW00000001NEWDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] AS t
--  WHERE CONVERT(bigint, t.MSP_No) > ISNULL((SELECT max_no_before FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907 WHERE db_name = 'NEW00000001NEWDB'), 0);

-- DELETE t FROM [NEW00000002NEWDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] AS t
--  WHERE CONVERT(bigint, t.MSP_No) > ISNULL((SELECT max_no_before FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907 WHERE db_name = 'NEW00000002NEWDB'), 0);

-- DELETE t FROM [NEW00000015NEWDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] AS t
--  WHERE CONVERT(bigint, t.MSP_No) > ISNULL((SELECT max_no_before FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907 WHERE db_name = 'NEW00000015NEWDB'), 0);

-- DELETE t FROM [NEW00000017NEWDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] AS t
--  WHERE CONVERT(bigint, t.MSP_No) > ISNULL((SELECT max_no_before FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907 WHERE db_name = 'NEW00000017NEWDB'), 0);

-- DELETE t FROM [NEW00000020NEWDB].[dbo].[tbl_tori_ManufacturerSpecialPrice] AS t
--  WHERE CONVERT(bigint, t.MSP_No) > ISNULL((SELECT max_no_before FROM [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907 WHERE db_name = 'NEW00000020NEWDB'), 0);
GO


/* ============================================================================
   STEP 7 : 後片付け（業務確認まで終わってから）
   ---------------------------------------------------------------------------
   ★ 作業用テーブルを消すと STEP 6 の取り消しができなくなる。
     業務確認まで終わったことを確認してから、コメントを外して実行する。
   ============================================================================ */
-- DROP TABLE [ExecutionBudgetDB].dbo.tbl_work_MSP_Copy_20260907;
-- GO


/* ============================================================================
   作業チェックリスト
   ---------------------------------------------------------------------------
   [ ] STEP 0-1 コピー先 DB に利用者がいないことを確認した
   [ ] STEP 0-2 5 つの DB のフルバックアップを取得した
   [ ] STEP 1-1 5 つの DB とテーブルが存在することを確認した
   [ ] STEP 1-2 列構成に diff が無いこと／MSP_No の IDENTITY 有無を確認した
   [ ] STEP 2   作業用テーブルを作成した
   [ ] STEP 3-1 投入予定件数を確認した（コピー元件数 = 投入予定 + 重複スキップ）
   [ ] STEP 3-2 単価・掛率の差異を確認し、上書きしない方針で問題ないことを確認した
   [ ] STEP 4   投入し、［メッセージ］タブにスキップされた DB が無いことを確認した
   [ ] ★ STEP 6 を実行していない（実行すると STEP 4 の投入が取り消される）
   [ ] STEP 5-1 判定がすべて OK であることを確認した
   [ ] STEP 5-2 データを目視確認した
   [ ] 業務確認（システムからメーカー特価が参照できる）を完了した
   [ ] STEP 7   作業用テーブルを削除した
   [ ] 記録を Git にコミットした
   ============================================================================ */
