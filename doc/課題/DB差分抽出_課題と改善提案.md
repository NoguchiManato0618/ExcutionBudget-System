# システム更新時のデータベース差分抽出 — 課題と改善提案

作成日: 2026-09-07
対象: 実行予算システム（ベンダー提供パッケージ / Windows Server + SQL Server）

---

## 1. 前提条件

| 項目 | 内容 |
| --- | --- |
| システム本体 | ベンダー提供。**自社では管理しておらず、プログラム改修は不可** |
| 更新時に入手できるもの | **発行ファイル（モジュール一式）のみ**。DB 変更の仕様書・差分 DDL・リリースノートは提供されない |
| 基盤 | Windows Server、SQL Server（オンプレミス） |
| **作業の範囲** | **データ移行は行わない。DB の構造（スキーマ）変更のみが対象。既存データはその場に保持したまま `ALTER` で構造を合わせる** |
| 現状の差分抽出手順 | ①更新後 DB のスクリプトを出力 → ②変更したい DB の内容もコピー → ③両方を AI に読ませて差分 SQL を作成してもらう |

**したがって、採用できる施策は「DB を外部から読み取るだけで完結し、システム本体に手を入れないもの」に限られる。**

---

## 2. 現状手順の課題

| # | 課題 | 具体的な症状 | 影響 |
| --- | --- | --- | --- |
| C1 | 差分抽出が人手 + AI 依存で**再現性がない** | 実行するたびに結果が微妙に変わる。手順が文書化されていない | 属人化。担当者が変わると再現不能 |
| C2 | **スクリプト全文を AI に渡している** | オブジェクト数が増えるとコンテキスト長を超え、途中が欠落する | 差分の**取りこぼし**（気付けない） |
| C3 | **2 者比較の限界** | 「更新後 DB」と「自社 DB」を比べると、*ベンダーの変更* と *自社のカスタマイズ / データ差* が混在する | 自社追加オブジェクトを DROP する事故。逆にベンダー変更の適用漏れ |
| C4 | **既存データを保持できるか判断できない** | 生成した SQL がテーブル再作成（DROP → CREATE）や桁縮小を伴わないか、目視でしか確認できない | **データ消失**。構造変更のみのはずが実データを失う |
| C5 | **生成した差分 SQL の検証手段がない** | 本番に当ててみるまで正しいか分からない | 障害リスク・切り戻し困難 |
| C6 | **履歴が残らない** | 「前回のバージョンで何が変わったか」を後から追えない | 原因調査に時間がかかる |
| C7 | 作業時間が長い | 更新のたびに数時間〜数日 | 更新頻度に対応できない |

---

## 3. あるべき姿（要件）

| ID | 要件 |
| --- | --- |
| R1 | **読み取り専用**で完結。システム本体・本番 DB を改変しない |
| R2 | **コマンド 1 発**で差分 SQL が機械的に生成される（再現性・自動化） |
| R3 | **既存データを保持したまま**構造変更できる（データ移行は行わないため、テーブル再作成・桁縮小を検出して止められること）。データ差分の抽出は対象外 |
| R4 | バージョンごとの**スキーマスナップショットを履歴保存**（Git 管理） |
| R5 | 差分が**人間がレビューできる粒度**で出力される |
| R6 | **検証環境で適用テスト**してから本番反映できる |
| R7 | 無料〜低コストで、**Windows Server 上で動作**する |

---

## 4. 改善提案

### 4-1. 【最重要】比較の考え方を「2 者比較」から「3 世代比較」に変える

現状の「更新後 DB ↔ 自社 DB」の 2 者比較は、原理的にベンダーの変更と自社の差分を区別できない。次の 3 つを用意して比較する。

```
  A : 更新前の状態のDB       ─┐
                              ├─ (A → B の差分) = 今回の更新でベンダーが加えた変更  ★これが欲しいもの
  B : 発行ファイル適用後のDB ─┘

  C : 自社の本番DB            ── (A → C の差分) = 自社カスタマイズ  ★消してはいけないもの

  本番への適用 = 「A→B の差分」だけを C に当てる
```

**現実的な実現方法（ベンダーの素の DB が入手できない場合）**

1. 検証機に**本番 DB のバックアップを復元**する（= A）
2. その状態で**スナップショットを取得**（後述のスクリプト出力）
3. 検証機に**発行ファイルを適用**する（＝ベンダーの更新処理を実際に走らせる）
4. 適用後に**再度スナップショットを取得**（= B）
5. **A → B の差分 = 今回の更新による DB 変更**。これをそのまま本番用の差分 SQL とする

> この方法なら「更新前後で同一の DB を比べる」ことになるため、自社カスタマイズは A・B の両方に等しく含まれ、**差分としては現れない**。C3 の課題が構造的に解消する。
> 現在の運用に対する最大の改善点は、**「更新を適用する前に、必ずスナップショットを取る」** という 1 点である。

---

### 4-2. 差分抽出ツールの比較

対象はスキーマのみのため、データ比較機能は評価対象外とする。

| # | 方式 | ツール | 費用 | 自動化(CLI) | 差分SQL自動生成 | 評価 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | **DacFx / SqlPackage** | `SqlPackage.exe` | 無料 | ◎ | ◎ | **★第 1 候補**。データ損失を伴う変更を検出して停止できる |
| 2 | スクリプト出力 + Git diff | `mssql-scripter` | 無料 | ◎ | ×（目視） | ★併用推奨（履歴・レビュー用） |
| 3 | 自作スクリプタ | PowerShell + SMO | 無料 | ◎ | ×（目視） | 2 が使えない場合の代替 |
| 4 | GUI スキーマ比較 | SSDT（Visual Studio）/ Azure Data Studio + SQL Database Projects 拡張 | 無料 | △ | ◎ | 目視確認・スポット調査向き |
| 5 | 商用比較ツール | Redgate SQL Compare、dbForge Schema Compare | 有償 | ◎ | ◎ | 予算が付くなら最短。生成 SQL の可読性が高い |
| 6 | カタログビュー比較 | `sys.*` / `INFORMATION_SCHEMA` を CSV 化して diff | 無料 | ◎ | ×（自作） | 軽量。簡易チェック用 |
| 7 | **DDL の実行ログ採取** | DDL トリガー / 既定トレース / SQL Server Audit | 無料 | ○ | ×（生 DDL が取れる） | ★有力な補助策（4-5 参照） |

---

### 4-3. 第 1 候補：SqlPackage（DacFx）で差分 SQL を自動生成する

Microsoft 純正・無料の CLI。DB を `.dacpac`（スキーマのスナップショット）として抽出し、2 つの `.dacpac` を比較して **差分の ALTER / CREATE スクリプトを自動生成**できる。要件 R1・R2・R5・R7 を満たす。

#### インストール

```powershell
# .NET SDK がある場合
dotnet tool install -g microsoft.sqlpackage
# または Microsoft サイトから "SqlPackage" スタンドアロン版をダウンロードして配置
```

#### 手順

```powershell
# ── ① 更新前スナップショットを抽出（読み取りのみ） ──
SqlPackage /Action:Extract `
  /SourceServerName:"SQLSRV\INSTANCE" /SourceDatabaseName:"BudgetDB" `
  /TargetFile:"D:\dbsnapshot\before.dacpac" `
  /p:ExtractAllTableData=False `
  /p:IgnorePermissions=True /p:IgnoreUserLoginMappings=True

# ── ② ここで検証機に発行ファイルを適用（ベンダーの更新処理を実行） ──

# ── ③ 更新後スナップショットを抽出 ──
SqlPackage /Action:Extract `
  /SourceServerName:"SQLSRV\INSTANCE" /SourceDatabaseName:"BudgetDB" `
  /TargetFile:"D:\dbsnapshot\after.dacpac" `
  /p:ExtractAllTableData=False `
  /p:IgnorePermissions=True /p:IgnoreUserLoginMappings=True

# ── ④ 差分 SQL を生成（after を「あるべき姿」、before を「現状」として ALTER 文を出力） ──
SqlPackage /Action:Script `
  /SourceFile:"D:\dbsnapshot\after.dacpac" `
  /TargetFile:"D:\dbsnapshot\before.dacpac" `
  /TargetDatabaseName:"BudgetDB" `
  /OutputPath:"D:\dbsnapshot\diff_v1.2_to_v1.3.sql" `
  /p:DropObjectsNotInSource=False `
  /p:BlockOnPossibleDataLoss=True `
  /p:IgnorePermissions=True `
  /p:IgnoreUserSettingsObjects=True `
  /p:IgnoreFileAndLogFilePath=True `
  /p:IgnoreFilegroupPlacement=True `
  /p:ExcludeObjectTypes="Users;Logins;RoleMembership;Permissions;Credentials"
```

> `/Action:Script` の Target には `.dacpac`（オフライン比較）と実 DB（`/TargetServerName` + `/TargetDatabaseName`）のどちらも指定できる。実 DB を指定しても**スクリプトを出力するだけで DB は変更されない**（実際に更新を実行するのは `/Action:Publish`。**本番に対して Publish は使わない**）。
> オプション名はバージョンによって差があるため、導入時に `SqlPackage /?` で確認すること。

#### 重要オプションの意味

| オプション | 目的 |
| --- | --- |
| `DropObjectsNotInSource=False` | **自社で追加したオブジェクトを DROP させない**（最重要の安全弁） |
| `BlockOnPossibleDataLoss=True` | 桁縮小・列削除などデータ損失を伴う変更でスクリプト生成を止める |
| `IgnorePermissions` / `ExcludeObjectTypes` | ユーザー・ログイン・権限など**環境差のノイズを除去** |
| `IgnoreFileAndLogFilePath` / `IgnoreFilegroupPlacement` | 物理ファイル配置の差を無視 |
| `ExtractAllTableData=False` | スキーマのみ抽出（データは対象外） |

#### 得られる効果

- 差分 SQL が**機械的に**生成される（C1・C2 の解消）
- `.dacpac` を保存すれば**バージョンごとの正本**になる（C6 の解消）
- AI の役割が「差分 SQL を作る」から「**生成された差分をレビューし、業務影響とリスクを説明させる**」に変わる。渡す情報量が桁違いに小さくなり、取りこぼしがなくなる

---

### 4-4. 併用推奨：スキーマスナップショットを Git で履歴管理する

`.dacpac` はバイナリのため人間には読めない。**オブジェクト単位のテキストファイル**としても出力し Git にコミットしておくと、`git diff` で変更点が一目で分かる。

#### 案 A: mssql-scripter（Microsoft 製、無料）

```powershell
pip install mssql-scripter

mssql-scripter -S "SQLSRV\INSTANCE" -d BudgetDB `
  --file-per-object -f "D:\dbsnapshot\schema" `
  --exclude-headers --script-create --display-progress
```

#### 案 B: PowerShell + SMO（追加インストール不要で確実）

```powershell
# scripts/Export-DbSchema.ps1
param(
  [Parameter(Mandatory)][string]$ServerInstance,
  [Parameter(Mandatory)][string]$Database,
  [Parameter(Mandatory)][string]$OutDir
)

Import-Module SqlServer
$srv = New-Object Microsoft.SqlServer.Management.Smo.Server $ServerInstance
$db  = $srv.Databases[$Database]

$opt = New-Object Microsoft.SqlServer.Management.Smo.ScriptingOptions
$opt.ScriptDrops        = $false
$opt.Indexes            = $true
$opt.DriAll             = $true     # PK/FK/制約
$opt.Triggers           = $true
$opt.ExtendedProperties = $true
$opt.NoCollation        = $true     # 環境差ノイズの除去
$opt.AnsiPadding        = $false
$opt.IncludeHeaders     = $false    # ★生成日時が入ると毎回差分になるので必ず false

function Save-Objects($collection, $subDir) {
  $dir = Join-Path $OutDir $subDir
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  foreach ($o in $collection) {
    if ($o.IsSystemObject) { continue }
    $name = "$($o.Schema).$($o.Name)" -replace '[\\/:*?"<>|]', '_'
    $o.Script($opt) | Out-File (Join-Path $dir "$name.sql") -Encoding utf8
  }
}

Save-Objects $db.Tables                'Tables'
Save-Objects $db.Views                 'Views'
Save-Objects $db.StoredProcedures      'StoredProcedures'
Save-Objects $db.UserDefinedFunctions  'Functions'
Save-Objects $db.UserDefinedTableTypes 'Types'
Save-Objects $db.Synonyms              'Synonyms'
```

#### 運用イメージ

```
doc/db-snapshot/
  v1.2.0/  Tables/  Views/  StoredProcedures/ ...
  v1.3.0/  Tables/  Views/  StoredProcedures/ ...
```

```powershell
# 更新前後の差分を人間可読な形で確認する
git diff --no-index doc/db-snapshot/v1.2.0 doc/db-snapshot/v1.3.0 > diff_v1.2_v1.3.patch
```

- **この patch ファイルだけを AI に渡せばよい**（C2 の根本解決）
- オブジェクト単位のファイルなので「どのストアドが変わったか」が一目で分かる（R5）
- `IncludeHeaders = $false` は必須。生成日時が入ると毎回全ファイルが差分扱いになる

---

### 4-5. 補助策：実際に発行された DDL をそのまま記録する

差分を「計算」するのではなく、**更新プログラムが実行した DDL を検証機で直接記録**してしまう方法。最も正確で、実行順序や依存関係まで残る。

```sql
-- ※必ず「検証機の DB」にのみ設置する。本番には入れない
CREATE TABLE dbo.DDL_ChangeLog (
    LogId       int IDENTITY(1,1) PRIMARY KEY,
    OccurredAt  datetime2     NOT NULL DEFAULT SYSDATETIME(),
    LoginName   sysname       NOT NULL DEFAULT ORIGINAL_LOGIN(),
    EventType   nvarchar(100) NULL,
    ObjectName  nvarchar(256) NULL,
    CommandText nvarchar(max) NULL
);
GO

CREATE TRIGGER trg_CaptureDDL ON DATABASE
FOR DDL_DATABASE_LEVEL_EVENTS
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @d xml = EVENTDATA();
    INSERT dbo.DDL_ChangeLog (EventType, ObjectName, CommandText)
    VALUES (
      @d.value('(/EVENT_INSTANCE/EventType)[1]',  'nvarchar(100)'),
      @d.value('(/EVENT_INSTANCE/ObjectName)[1]', 'nvarchar(256)'),
      @d.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', 'nvarchar(max)')
    );
END;
GO
```

手順：検証機に本番相当を復元 → 上記トリガーを設置 → **発行ファイルを適用** → `dbo.DDL_ChangeLog` を参照。更新プログラムが実行した DDL が時系列でそのまま取得できる。確認後にトリガーとログテーブルを削除する。

トリガーを設置できない場合の代替：

- **既定トレース**：SSMS の［レポート］→［標準レポート］→［スキーマ変更履歴］。設定不要だがログはローテーションで消えるため、更新直後に確認すること
- **発行ファイル自体の中身を確認**：インストーラに `.sql` が同梱されていることが多い

```powershell
Get-ChildItem -Recurse "D:\発行ファイル" -Include *.sql,*.dacpac,*.txt |
  Select-String -Pattern 'CREATE TABLE|ALTER TABLE|CREATE PROC|ALTER PROC' |
  Group-Object Path | Select-Object Count, Name
```

---

### 4-6. 既存データを保持したまま構造変更するための注意点

**データ移行を行わない前提のため、「生成された差分 SQL が既存データを壊さないか」の確認が最重要工程になる。**
注意すべきは、比較ツールの生成スクリプトが変更内容によっては単純な `ALTER` ではなく **テーブル再作成（作業用テーブル作成 → データ移送 → 旧テーブル DROP → リネーム）** を行う点である。

#### 変更内容ごとの挙動

| 変更内容 | SQL Server の挙動 | 注意点 |
| --- | --- | --- |
| 列の追加（NULL 許容 / DEFAULT 付き） | メタデータ操作のみ | 安全。ほとんどの更新はこれ |
| 列の追加（NOT NULL・DEFAULT なし） | エラー | 既存行があると追加不可。DEFAULT を付けるか、NULL 許容で追加 → UPDATE → NOT NULL 化の 3 段階に分ける |
| 桁の拡大（`nvarchar(20)`→`(50)` 等） | `ALTER COLUMN` で可 | 安全 |
| **桁の縮小・型変更** | 変換エラー／切り捨て | **適用前に実データが収まるか確認必須**（下記 SQL） |
| **列の削除** | データ消失 | ベンダー更新の意図を確認。安易に適用しない |
| 主キー / IDENTITY / 列順の変更 | ツールが **テーブル再作成**を生成することがある | 大テーブルでは長時間ロック＋大量ログ。生成 SQL に作業用テーブル（`tmp_ms_xx_` 等）が出たら要注意 |
| インデックス・制約の追加／削除 | 安全 | ただし大テーブルでは所要時間とロックに注意 |
| 照合順序の変更 | インデックス再構築を伴う | 影響範囲が大きい。単独で計画する |

#### 生成した差分 SQL の危険パターン検査（適用前に必ず実施）

```powershell
Select-String -Path "D:\dbsnapshot\diff_v1.2_to_v1.3.sql" `
  -Pattern 'DROP TABLE|DROP COLUMN|TRUNCATE|tmp_ms_xx|ALTER COLUMN'
```

ヒットした箇所は 1 件ずつ内容を確認する。ここが AI にレビューさせるのに最も向いている部分。

#### 桁縮小・型変更が含まれる場合の事前確認

```sql
-- 例: nvarchar(50) → nvarchar(20) への縮小が差分にある場合
SELECT MAX(LEN(ProjectName)) AS MaxLen, COUNT(*) AS OverCount
FROM dbo.T_Budget
WHERE LEN(ProjectName) > 20;
```

#### 適用前後の検証：全テーブルの行数を比較する

構造変更のみでデータ移行しないのだから、**適用前後で行数は変わらないはず**。これは機械的で確実な検証項目になる。

```sql
-- 適用前・適用後の両方で実行し、結果を CSV 保存して比較する
SELECT s.name AS schema_name, t.name AS table_name, SUM(p.rows) AS row_count
FROM sys.tables t
JOIN sys.schemas s     ON s.schema_id = t.schema_id
JOIN sys.partitions p  ON p.object_id = t.object_id AND p.index_id IN (0, 1)
GROUP BY s.name, t.name
ORDER BY s.name, t.name;
```

```powershell
Invoke-Sqlcmd -ServerInstance "SQLSRV\INSTANCE" -Database BudgetDB -InputFile .\rowcount.sql |
  Export-Csv "D:\dbsnapshot\rowcount_before.csv" -NoTypeInformation -Encoding UTF8
# 適用後に rowcount_after.csv を取得し、diff を取る
```

行数が変わっていたら、意図しないテーブル再作成やデータ削除が起きている。

#### 切り戻しの備え

- 適用前に**フルバックアップ**を取得（必須）
- 短時間で戻したい場合は **データベーススナップショット**も有効
  ```sql
  CREATE DATABASE BudgetDB_Snap ON (NAME = BudgetDB, FILENAME = 'D:\snap\BudgetDB.ss')
    AS SNAPSHOT OF BudgetDB;
  -- 切り戻し
  -- RESTORE DATABASE BudgetDB FROM DATABASE_SNAPSHOT = 'BudgetDB_Snap';
  ```
  ※エディションによって利用可否が異なるため、事前に検証機で動作確認すること
- 差分 SQL は可能な範囲でトランザクションに包み、エラー時にロールバックさせる

---

### 4-7. 新規に自作する場合の設計案

既存ツールで足りない部分（自社の運用に合わせた台帳管理・レポート出力）を埋める場合の最小構成。

```
DbDiffTool/
  Export-DbSchema.ps1     # スキーマをオブジェクト単位でファイル出力（4-4 案B）
  Export-RowCount.ps1     # 全テーブルの行数を CSV 出力（適用前後の検証用・4-6）
  New-SchemaDiff.ps1      # SqlPackage を呼んで差分 SQL を生成（4-3 のラッパ）
  Test-DiffSafety.ps1     # 生成 SQL の危険パターン（DROP / 再作成 / 桁縮小）を検査（4-6）
  New-DiffReport.ps1      # 差分を Markdown レポート化（人間 / AI レビュー用）
  config/
    ignore.json           # 差分として無視する対象（ユーザー、権限、統計情報 等）
  output/
    v1.2.0_to_v1.3.0/
      diff.sql
      safety.md           # 危険パターン検査の結果
      rowcount_before.csv / rowcount_after.csv
      report.md
```

- 実装は **PowerShell（SMO / SqlPackage 呼び出し）** を推奨。Windows Server にそのまま置ける、追加ランタイム不要、担当者が読める
- **比較エンジンは自作しない**。DacFx（SqlPackage）を呼ぶだけにする。SQL Server のスキーマ比較は依存順序・型の等価性・照合順序など考慮点が非常に多く、自作すると必ず穴が出る
- 自作するのは「**運用に合わせた入出力・台帳管理・レポート整形**」の部分に限定する
- 想定工数：PoC 1〜2 人日、運用に載せるまで 3〜5 人日程度

#### レポート出力（AI レビュー用）のイメージ

```markdown
# DB差分レポート  v1.2.0 → v1.3.0

## サマリ
- 追加テーブル: 2 / 変更テーブル: 5 / 削除テーブル: 0
- 変更ストアド: 12 / 追加ビュー: 1
- 要注意: T_Budget.Amount の桁変更（decimal(12,0) → decimal(15,0)）

## 詳細
### T_Budget（変更）
+ ALTER TABLE dbo.T_Budget ADD ProjectCode nvarchar(20) NULL;
...
```

このレポートを AI に渡して「**業務影響・実行順序・切り戻し手順**」をレビューさせるのが、現状のやり方より圧倒的に効率がよく安全。

---

## 5. 導入ロードマップ

| Step | 内容 | 目的 | 目安 |
| --- | --- | --- | --- |
| 0 | 現状把握：SQL Server バージョン、DB サイズ、オブジェクト数、検証機の有無、DB 接続権限（読み取り可否）を確認 | 前提固め | 0.5 日 |
| 1 | **更新前スナップショットの取得を運用ルール化**（`.dacpac` + テキスト出力を必ず取る） | C3・C6 の即時緩和。**最優先** | 0.5 日 |
| 2 | SqlPackage を検証機に導入し、過去バージョン間で差分 SQL 生成を PoC | 有効性の確認 | 1 日 |
| 3 | スナップショットを Git 管理し、PowerShell でワンコマンド化 | C1・C2・C7 の解消 | 2 日 |
| 4 | 検証機での適用テスト手順・チェックリストを整備 | C5 の解消 | 1 日 |
| 5 | 危険パターン検査（DROP / テーブル再作成 / 桁縮小）と適用前後の行数比較を自動化 | C4 の解消 | 1 日 |
| 6 | （任意）DDL トリガーによる実 DDL 採取、商用ツール導入検討 | 精度向上 | — |

**Step 1 だけは、次回の更新前に必ず実施すること。** これを逃すと「更新前の状態」が永久に失われ、以降ずっと精度の低い 2 者比較を続けることになる。

---

## 6. 更新作業チェックリスト（案）

- [ ] 本番 DB のフルバックアップを取得した
- [ ] 検証機に本番相当を復元した
- [ ] **更新前スナップショット**（`.dacpac` + スキーマのテキスト出力 + **全テーブル行数 CSV**）を取得し、Git にコミットした
- [ ] 検証機で発行ファイルを適用した
- [ ] **更新後スナップショット**を取得し、Git にコミットした
- [ ] 差分 SQL を生成した（`DropObjectsNotInSource=False` を指定した）
- [ ] 差分 SQL の**危険パターン検査**を実施した（`DROP TABLE` / `DROP COLUMN` / `TRUNCATE` / 作業用テーブルによるテーブル再作成 / `ALTER COLUMN` の桁縮小）
- [ ] 桁縮小・型変更がある場合、実データが収まることを SELECT で確認した
- [ ] 自社カスタマイズしたオブジェクトが差分に含まれていないか確認した
- [ ] 差分 SQL を検証機のクリーンな復元 DB に適用し、エラーが出ないことを確認した
- [ ] **適用前後で全テーブルの行数が一致すること**を確認した（データ移行しないため件数は不変のはず）
- [ ] 大テーブルの変更がある場合、適用所要時間を検証機で計測した
- [ ] 業務主要機能の動作確認を行った
- [ ] 切り戻し手順（バックアップ／DB スナップショット）を用意した
- [ ] 本番へ適用し、適用後スナップショットを取得した

---

## 7. リスク・注意事項

| リスク | 内容 | 対策 |
| --- | --- | --- |
| 自社オブジェクトの消失 | 比較ツールが「ソースに無い＝削除」と判断する | `DropObjectsNotInSource=False` を必ず指定。生成 SQL の `DROP` を目視確認 |
| データ損失 | 列削除・桁縮小を含む `ALTER`（データ移行しない前提のため致命的） | `BlockOnPossibleDataLoss=True`。危険パターン検査（4-6）を必須工程にする |
| 意図しないテーブル再作成 | 主キー変更・列順変更などでツールが「作成 → 移送 → DROP → リネーム」を生成する | 生成 SQL で作業用テーブルの有無を検査。大テーブルでは長時間ロック・ログ肥大 → メンテナンス時間帯に実施し、所要時間を検証機で計測 |
| 環境差のノイズ | ユーザー、権限、ファイルパス、照合順序の違いが差分として出る | `ExcludeObjectTypes` / `Ignore*` オプションで除外。除外方針を `ignore.json` に文書化 |
| 生成 SQL の実行順序 | 依存関係により単純適用でエラーになることがある | 必ず検証機で通してから本番へ。トランザクション化を検討 |
| ベンダー保守契約 | DB への直接操作が保守対象外になる可能性 | **スナップショット取得は読み取り専用**である旨を説明。DDL トリガーは検証機限定とし、事前にベンダー確認 |
| 権限不足 | `Extract` には DB のメタデータ読み取り権限が必要 | 専用の読み取りアカウントを用意（`db_datareader` + `VIEW DEFINITION`） |
| スナップショットの保管 | Git に大量ファイルが入る | テキストのみ Git 管理、`.dacpac` は共有フォルダまたは Git LFS。バージョンタグと紐付ける |

---

## 8. 要確認事項

1. 検証（ステージング）環境は用意できるか。本番 DB のバックアップを復元できるか
2. 発行ファイルの中に `.sql` / `.dacpac` などの DB 更新スクリプトが同梱されていないか（あれば本課題の大部分が不要になる）
3. ベンダーに **DB 変更点の資料（ER 図・差分 DDL・リリースノート）の提供を依頼できないか** ← まずこれを打診するのが最も低コスト
4. 検証機の DB に DDL トリガーを一時設置してよいか（保守契約上の可否）
5. 自社で追加・改変しているオブジェクトの一覧は把握できているか（未把握なら棚卸しが必要）
6. 商用ツール（Redgate / dbForge 等）の購入予算が取れるか
7. 大規模テーブル（数百万件以上）の有無。テーブル再作成を伴う変更が来た場合の停止可能時間はどれくらいか
8. 更新作業時にシステムを停止できる時間枠（メンテナンスウィンドウ）

---

## 9. まとめ

| 現状 | 改善後 |
| --- | --- |
| 更新後 DB と自社 DB を 2 者比較 | **更新前後の同一 DB を比較**（自社カスタマイズが差分に混ざらない） |
| スクリプト全文を AI に渡して差分 SQL を作らせる | **SqlPackage が差分 SQL を機械生成**。AI は差分のレビューと影響調査に使う |
| 手順が属人的・非再現 | PowerShell でワンコマンド化 |
| 履歴なし | Git にバージョンごとのスキーマスナップショットを保存 |
| 検証手段なし | 検証機での適用テストをチェックリスト化 |
| データを壊さないか目視頼み | 危険パターン検査 + **適用前後の行数一致確認**で機械的に担保 |

対象は**構造（スキーマ）のみ**。データ移行は行わないため、
「既存データを保持したまま `ALTER` で構造を合わせられるか」の担保が最重要工程になる（4-6）。

**最初にやること：次回更新の前に「更新前スナップショット」を取る運用を始める。**
これだけで差分抽出の精度と安全性が大きく変わる。ツール導入はその後でよい。

---

## 参考

- SqlPackage（Microsoft Learn）: https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage
- SqlPackage 発行プロパティ一覧: https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-publish
- mssql-scripter: https://github.com/microsoft/mssql-scripter
- SQL Database Projects 拡張（Azure Data Studio / VS Code）: https://learn.microsoft.com/azure-data-studio/extensions/sql-database-project-extension
- DDL トリガー / EVENTDATA(): https://learn.microsoft.com/sql/relational-databases/triggers/ddl-triggers
