/* ============================================================================
   CompanyId データ複製スクリプト（MySQL）

   目的 : CompanyId = '12345678' の物件データ一式を、
          CompanyId = 1, 2, 5, 15, 17, 20 にコピーする（既存データへの追加）

   対象 : ExcutionBudget.PropertyInfo              … 親（物件）
          ExcutionBudget.ListOfMaterials           ─┐
          ExcutionBudget.ListOfExpences             │ 子（EntryId で親に紐づく）
          ExcutionBudget.ListOfEstimationResults    │
          ExcutionBudget.ListOfEstimates           ─┘

   ---------------------------------------------------------------------------
   ★ 調査で判明した前提 ★

   ・PropertyInfo.EntryId は AUTO_INCREMENT ではなく、UNIQUE 制約（uq_entry_id）
     が付いた文字列。全社通しで一意。
   ・値の形式は 18 桁　例: 260828091027fh6lho
       260828  … 日付 YYMMDD
       091027  … 時刻 HHMMSS
       fh6lho  … ランダム 6 文字（英小文字・数字）
   ・子テーブルは EntryId で親を参照している。

   → コピー時は新しい EntryId を採番し、親と子で同じ値を使う必要がある。
     テーブル単位の一括コピーは不可。

   ---------------------------------------------------------------------------
   ★ 新しい EntryId の採番規則 ★

       新EntryId = 元EntryId + '-' + 複製先CompanyId
       例) 260828091027fh6lho  →  260828091027fh6lho-5

   ・複製先の CompanyId が異なるので、必ず一意になる
   ・どの物件からコピーしたものかが値を見れば分かる
   ・取り消すときも '-' 以降で判別できる

   ※ EntryId 列の桁数が足りないと入らないため、STEP 3 と
     プロシージャ内の両方で長さをチェックしている。
   ---------------------------------------------------------------------------
   ---------------------------------------------------------------------------

   進め方 : STEP 0 → 1 → 2 → 3 → 4 → 5 → COMMIT → 6 の順に、
            各ブロックを選択して実行する。全体をまとめて流さないこと。
   ============================================================================ */


/* ============================================================================
   STEP 0-1 : 開いているトランザクションを閉じる（毎回最初に実行）
   ============================================================================ */
ROLLBACK;
SET SQL_SAFE_UPDATES = 0;


/* ============================================================================
   STEP 0-2 : バックアップを取得する（★必須）
   ---------------------------------------------------------------------------
   コマンドプロンプトで実行する（MySQL 上ではない）
   ============================================================================ */
/*
mysqldump -u root -p --single-transaction ExcutionBudget ^
  PropertyInfo ListOfMaterials ListOfExpences ListOfEstimationResults ListOfEstimates ^
  > C:\dbdiff\ExcutionBudget_backup_20260907.sql
*/


/* ============================================================================
   STEP 1 : 誤挿入が残っていないか確認する
   ---------------------------------------------------------------------------
   「CompanyId は 1/2/5/15/17/20 なのに、EntryId は 12345678 の物件」を数える。
   → 0 件（結果なし）なら STEP 3 へ
   → 件数が出たら STEP 2 で削除する
   ============================================================================ */
SELECT 'ListOfMaterials' AS tbl, CompanyId, COUNT(*) AS bad_rows
  FROM ExcutionBudget.ListOfMaterials
 WHERE CompanyId IN ('1','2','5','15','17','20')
   AND EntryId IN (SELECT EntryId FROM ExcutionBudget.PropertyInfo WHERE CompanyId = '12345678')
 GROUP BY CompanyId
UNION ALL
SELECT 'ListOfExpences', CompanyId, COUNT(*)
  FROM ExcutionBudget.ListOfExpences
 WHERE CompanyId IN ('1','2','5','15','17','20')
   AND EntryId IN (SELECT EntryId FROM ExcutionBudget.PropertyInfo WHERE CompanyId = '12345678')
 GROUP BY CompanyId
UNION ALL
SELECT 'ListOfEstimationResults', CompanyId, COUNT(*)
  FROM ExcutionBudget.ListOfEstimationResults
 WHERE CompanyId IN ('1','2','5','15','17','20')
   AND EntryId IN (SELECT EntryId FROM ExcutionBudget.PropertyInfo WHERE CompanyId = '12345678')
 GROUP BY CompanyId
UNION ALL
SELECT 'ListOfEstimates', CompanyId, COUNT(*)
  FROM ExcutionBudget.ListOfEstimates
 WHERE CompanyId IN ('1','2','5','15','17','20')
   AND EntryId IN (SELECT EntryId FROM ExcutionBudget.PropertyInfo WHERE CompanyId = '12345678')
 GROUP BY CompanyId
ORDER BY tbl, CompanyId;


/* ============================================================================
   STEP 2 : 誤挿入データを削除する（STEP 1 で件数が出た場合のみ）
   ============================================================================ */
START TRANSACTION;

DELETE FROM ExcutionBudget.ListOfEstimates
 WHERE CompanyId IN ('1','2','5','15','17','20')
   AND EntryId IN (SELECT EntryId FROM ExcutionBudget.PropertyInfo WHERE CompanyId = '12345678');

DELETE FROM ExcutionBudget.ListOfEstimationResults
 WHERE CompanyId IN ('1','2','5','15','17','20')
   AND EntryId IN (SELECT EntryId FROM ExcutionBudget.PropertyInfo WHERE CompanyId = '12345678');

DELETE FROM ExcutionBudget.ListOfExpences
 WHERE CompanyId IN ('1','2','5','15','17','20')
   AND EntryId IN (SELECT EntryId FROM ExcutionBudget.PropertyInfo WHERE CompanyId = '12345678');

DELETE FROM ExcutionBudget.ListOfMaterials
 WHERE CompanyId IN ('1','2','5','15','17','20')
   AND EntryId IN (SELECT EntryId FROM ExcutionBudget.PropertyInfo WHERE CompanyId = '12345678');

/* STEP 1 を再実行して 0 件になったことを確認してから */
-- COMMIT;
-- ROLLBACK;


/* ============================================================================
   STEP 3-1 : EntryId 列の桁数を確認する（★重要）
   ---------------------------------------------------------------------------
   新 EntryId は「元EntryId(18) + '-' + CompanyId(1〜2)」= 20〜21 文字になる。
   5 テーブルすべての max_length が 21 以上あることを確認する。
   足りない場合は STEP 3-3 で列を拡張する。
   ============================================================================ */
SELECT TABLE_NAME, COLUMN_TYPE, CHARACTER_MAXIMUM_LENGTH AS max_length
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'ExcutionBudget'
  AND COLUMN_NAME  = 'EntryId'
  AND TABLE_NAME IN ('PropertyInfo','ListOfMaterials','ListOfExpences',
                     'ListOfEstimationResults','ListOfEstimates')
ORDER BY FIELD(TABLE_NAME,'PropertyInfo','ListOfMaterials','ListOfExpences',
                          'ListOfEstimationResults','ListOfEstimates');


/* ============================================================================
   STEP 3-2 : これから作られる EntryId を確認する（24 件）
   ---------------------------------------------------------------------------
   実際にコピー時に採番される値の一覧。
   ・dup が 1 の行があれば、その値は既に存在する（実行前に要確認）
   ============================================================================ */
SELECT p.EntryId                              AS 元EntryId,
       n.id                                   AS 複製先CompanyId,
       CONCAT(p.EntryId, '-', n.id)           AS 新EntryId,
       LENGTH(CONCAT(p.EntryId, '-', n.id))   AS 長さ,
       (SELECT COUNT(*) FROM ExcutionBudget.PropertyInfo z
         WHERE z.EntryId = CONCAT(p.EntryId, '-', n.id)) AS dup
  FROM ExcutionBudget.PropertyInfo p
 CROSS JOIN ( SELECT '1' AS id UNION ALL SELECT '2' UNION ALL SELECT '5'
              UNION ALL SELECT '15' UNION ALL SELECT '17' UNION ALL SELECT '20' ) n
 WHERE p.CompanyId = '12345678'
 ORDER BY n.id, p.EntryId;


/* ============================================================================
   STEP 3-3 : 桁数が足りない場合のみ実行する（★通常は不要）
   ---------------------------------------------------------------------------
   STEP 3-1 で max_length が 21 未満だった場合に、5 テーブルとも拡張する。
   ※ 外部キーで結ばれた列なので、必ず 5 つすべて同じ型に変更すること
   ※ COLUMN_TYPE が varchar 以外の場合はこの文を使わないこと
   ============================================================================ */
/*
SET FOREIGN_KEY_CHECKS = 0;
ALTER TABLE ExcutionBudget.PropertyInfo            MODIFY EntryId VARCHAR(32) NOT NULL;
ALTER TABLE ExcutionBudget.ListOfMaterials         MODIFY EntryId VARCHAR(32) NOT NULL;
ALTER TABLE ExcutionBudget.ListOfExpences          MODIFY EntryId VARCHAR(32) NOT NULL;
ALTER TABLE ExcutionBudget.ListOfEstimationResults MODIFY EntryId VARCHAR(32) NOT NULL;
ALTER TABLE ExcutionBudget.ListOfEstimates         MODIFY EntryId VARCHAR(32) NOT NULL;
SET FOREIGN_KEY_CHECKS = 1;
*/

/* 複製元の件数（1 社あたりの増加件数になる） */
SELECT 'PropertyInfo' AS tbl, COUNT(*) AS src_rows FROM ExcutionBudget.PropertyInfo            WHERE CompanyId='12345678'
UNION ALL SELECT 'ListOfMaterials',         COUNT(*) FROM ExcutionBudget.ListOfMaterials         WHERE CompanyId='12345678'
UNION ALL SELECT 'ListOfExpences',          COUNT(*) FROM ExcutionBudget.ListOfExpences          WHERE CompanyId='12345678'
UNION ALL SELECT 'ListOfEstimationResults', COUNT(*) FROM ExcutionBudget.ListOfEstimationResults WHERE CompanyId='12345678'
UNION ALL SELECT 'ListOfEstimates',         COUNT(*) FROM ExcutionBudget.ListOfEstimates         WHERE CompanyId='12345678';


/* ============================================================================
   STEP 4-1 : 記録用テーブルとプロシージャを作成する
   ---------------------------------------------------------------------------
   ※ DELIMITER 行を含めて、このブロックを丸ごと選択して実行すること
   ※ ここは DDL のため、トランザクションの外で実行する（STEP 4-2 より前）
   ============================================================================ */
CREATE TABLE IF NOT EXISTS ExcutionBudget.tmp_copy_log (
    seq        INT AUTO_INCREMENT PRIMARY KEY,
    cid        VARCHAR(50),
    src_entry  VARCHAR(100),
    new_entry  VARCHAR(100),
    created_at DATETIME
) ENGINE=InnoDB;

DROP PROCEDURE IF EXISTS ExcutionBudget.tmp_copy_property;

DELIMITER $$

CREATE PROCEDURE ExcutionBudget.tmp_copy_property(IN p_src VARCHAR(50))
BEGIN
    DECLARE v_done      INT DEFAULT 0;
    DECLARE v_cid       VARCHAR(50);
    DECLARE v_src_entry VARCHAR(100);
    DECLARE v_new_entry VARCHAR(100);
    DECLARE v_seq       INT DEFAULT 0;
    DECLARE v_bad       INT DEFAULT 0;
    DECLARE v_maxlen    INT DEFAULT 0;
    DECLARE v_need      INT DEFAULT 0;
    DECLARE v_tpl_pi    TEXT;
    DECLARE v_tpl_mat   TEXT;
    DECLARE v_tpl_exp   TEXT;
    DECLARE v_tpl_res   TEXT;
    DECLARE v_tpl_est   TEXT;

    /* 複製先の会社 × 複製元の物件（6 × 4 = 24 セット） */
    DECLARE cur CURSOR FOR
        SELECT n.id, p.EntryId
        FROM ( SELECT '1' AS id, 1 AS seq
               UNION ALL SELECT '2',  2
               UNION ALL SELECT '5',  3
               UNION ALL SELECT '15', 4
               UNION ALL SELECT '17', 5
               UNION ALL SELECT '20', 6 ) n
        CROSS JOIN ExcutionBudget.PropertyInfo p
        WHERE p.CompanyId = p_src
        ORDER BY n.seq, p.EntryId;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    SET SESSION group_concat_max_len = 1000000;

    /* ---- 前提チェック 1 : EntryId 列の桁数が足りるか ---- */
    SELECT MIN(CHARACTER_MAXIMUM_LENGTH) INTO v_maxlen
      FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = 'ExcutionBudget'
       AND COLUMN_NAME  = 'EntryId'
       AND TABLE_NAME IN ('PropertyInfo','ListOfMaterials','ListOfExpences',
                          'ListOfEstimationResults','ListOfEstimates');

    SELECT MAX(LENGTH(EntryId)) + 3 INTO v_need
      FROM ExcutionBudget.PropertyInfo
     WHERE CompanyId = p_src;

    IF v_maxlen IS NULL OR v_maxlen < v_need THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'EntryId 列の桁数が足りません。STEP 3-1 と 3-3 を確認してください。';
    END IF;

    /* ---- 前提チェック 2 : 生成予定の EntryId が既に存在しないか ---- */
    SELECT COUNT(*) INTO v_bad
      FROM ExcutionBudget.PropertyInfo p
     CROSS JOIN ( SELECT '1' AS id UNION ALL SELECT '2' UNION ALL SELECT '5'
                  UNION ALL SELECT '15' UNION ALL SELECT '17' UNION ALL SELECT '20' ) n
     WHERE p.CompanyId = p_src
       AND EXISTS (SELECT 1 FROM ExcutionBudget.PropertyInfo z
                    WHERE z.EntryId = CONCAT(p.EntryId, '-', n.id));

    IF v_bad > 0 THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = '生成予定の EntryId が既に存在します。STEP 3-2 の dup 列を確認してください。';
    END IF;

    /* ---- 親テーブルの雛形（CompanyId と EntryId を差し替える） ---- */
    SELECT CONCAT(
             'INSERT INTO `ExcutionBudget`.`PropertyInfo` (',
             GROUP_CONCAT(CONCAT('`', COLUMN_NAME, '`') ORDER BY ORDINAL_POSITION SEPARATOR ', '),
             ') SELECT ',
             GROUP_CONCAT(CASE WHEN COLUMN_NAME = 'CompanyId' THEN '<<CID>>'
                               WHEN COLUMN_NAME = 'EntryId'   THEN '<<NEW_ENTRY>>'
                               ELSE CONCAT('`', COLUMN_NAME, '`') END
                          ORDER BY ORDINAL_POSITION SEPARATOR ', '),
             ' FROM `ExcutionBudget`.`PropertyInfo`',
             ' WHERE `CompanyId` = <<SRC_CID>> AND `EntryId` = <<SRC_ENTRY>>')
      INTO v_tpl_pi
      FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = 'ExcutionBudget'
       AND TABLE_NAME   = 'PropertyInfo'
       AND EXTRA NOT LIKE '%auto_increment%'
       AND EXTRA NOT LIKE '%GENERATED%';

    /* ---- 子テーブルの雛形 ---- */
    DROP TEMPORARY TABLE IF EXISTS tmp_tpl;
    CREATE TEMPORARY TABLE tmp_tpl (tname VARCHAR(64) PRIMARY KEY, tpl TEXT);

    INSERT INTO tmp_tpl (tname, tpl)
    SELECT c.TABLE_NAME,
           CONCAT(
             'INSERT INTO `ExcutionBudget`.`', c.TABLE_NAME, '` (',
             GROUP_CONCAT(CONCAT('`', c.COLUMN_NAME, '`') ORDER BY c.ORDINAL_POSITION SEPARATOR ', '),
             ') SELECT ',
             GROUP_CONCAT(CASE WHEN c.COLUMN_NAME = 'CompanyId' THEN '<<CID>>'
                               WHEN c.COLUMN_NAME = 'EntryId'   THEN '<<NEW_ENTRY>>'
                               ELSE CONCAT('`', c.COLUMN_NAME, '`') END
                          ORDER BY c.ORDINAL_POSITION SEPARATOR ', '),
             ' FROM `ExcutionBudget`.`', c.TABLE_NAME, '`',
             ' WHERE `CompanyId` = <<SRC_CID>> AND `EntryId` = <<SRC_ENTRY>>')
      FROM information_schema.COLUMNS c
     WHERE c.TABLE_SCHEMA = 'ExcutionBudget'
       AND c.TABLE_NAME IN ('ListOfMaterials','ListOfExpences',
                            'ListOfEstimationResults','ListOfEstimates')
       AND c.EXTRA NOT LIKE '%auto_increment%'
       AND c.EXTRA NOT LIKE '%GENERATED%'
     GROUP BY c.TABLE_NAME;

    SELECT tpl INTO v_tpl_mat FROM tmp_tpl WHERE tname = 'ListOfMaterials';
    SELECT tpl INTO v_tpl_exp FROM tmp_tpl WHERE tname = 'ListOfExpences';
    SELECT tpl INTO v_tpl_res FROM tmp_tpl WHERE tname = 'ListOfEstimationResults';
    SELECT tpl INTO v_tpl_est FROM tmp_tpl WHERE tname = 'ListOfEstimates';

    SET v_done = 0;

    OPEN cur;
    copy_loop: LOOP
        FETCH cur INTO v_cid, v_src_entry;
        IF v_done = 1 THEN LEAVE copy_loop; END IF;

        SET v_seq = v_seq + 1;

        /* ---- 新しい EntryId を生成 ----
           元EntryId + '-' + 複製先CompanyId
           例) 260828091027fh6lho-5 */
        SET v_new_entry = CONCAT(v_src_entry, '-', v_cid);

        /* ① 親をコピー */
        SET @s = REPLACE(REPLACE(REPLACE(REPLACE(v_tpl_pi,
                     '<<CID>>',       QUOTE(v_cid)),
                     '<<NEW_ENTRY>>', QUOTE(v_new_entry)),
                     '<<SRC_CID>>',   QUOTE(p_src)),
                     '<<SRC_ENTRY>>', QUOTE(v_src_entry));
        PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

        /* ② 同じ EntryId で子 4 テーブルをコピー */
        SET @s = REPLACE(REPLACE(REPLACE(REPLACE(v_tpl_mat,
                     '<<CID>>',       QUOTE(v_cid)),
                     '<<NEW_ENTRY>>', QUOTE(v_new_entry)),
                     '<<SRC_CID>>',   QUOTE(p_src)),
                     '<<SRC_ENTRY>>', QUOTE(v_src_entry));
        PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

        SET @s = REPLACE(REPLACE(REPLACE(REPLACE(v_tpl_exp,
                     '<<CID>>',       QUOTE(v_cid)),
                     '<<NEW_ENTRY>>', QUOTE(v_new_entry)),
                     '<<SRC_CID>>',   QUOTE(p_src)),
                     '<<SRC_ENTRY>>', QUOTE(v_src_entry));
        PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

        SET @s = REPLACE(REPLACE(REPLACE(REPLACE(v_tpl_res,
                     '<<CID>>',       QUOTE(v_cid)),
                     '<<NEW_ENTRY>>', QUOTE(v_new_entry)),
                     '<<SRC_CID>>',   QUOTE(p_src)),
                     '<<SRC_ENTRY>>', QUOTE(v_src_entry));
        PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

        SET @s = REPLACE(REPLACE(REPLACE(REPLACE(v_tpl_est,
                     '<<CID>>',       QUOTE(v_cid)),
                     '<<NEW_ENTRY>>', QUOTE(v_new_entry)),
                     '<<SRC_CID>>',   QUOTE(p_src)),
                     '<<SRC_ENTRY>>', QUOTE(v_src_entry));
        PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

        /* ③ 記録（検証と取り消しに使う） */
        INSERT INTO ExcutionBudget.tmp_copy_log (cid, src_entry, new_entry, created_at)
        VALUES (v_cid, v_src_entry, v_new_entry, NOW());
    END LOOP;
    CLOSE cur;

    DROP TEMPORARY TABLE IF EXISTS tmp_tpl;

    SELECT CONCAT('物件 ', v_seq, ' 件をコピーしました（4物件 × 6社）') AS result;
END$$

DELIMITER ;


/* ============================================================================
   STEP 4-2 : 複製を実行する
   ============================================================================ */
START TRANSACTION;

CALL ExcutionBudget.tmp_copy_property('12345678');

/* STEP 5 を実行して確認してから COMMIT / ROLLBACK すること */


/* ============================================================================
   STEP 5-1 : 生成された EntryId を確認する（24 件）
   ============================================================================ */
SELECT seq, cid AS 複製先CompanyId, src_entry AS 元EntryId, new_entry AS 新EntryId
  FROM ExcutionBudget.tmp_copy_log
 ORDER BY seq;


/* ============================================================================
   STEP 5-2 : コピーされた件数を確認する
   ---------------------------------------------------------------------------
   1 物件あたり ListOfMaterials 65 / ListOfExpences 4 / ListOfEstimationResults 5 /
   ListOfEstimates 15 …のように、元の物件と同じ内訳になっていれば成功
   （合計は 1 社あたり 260 / 16 / 20 / 60）
   ============================================================================ */
SELECT l.cid AS CompanyId,
       COUNT(DISTINCT l.new_entry)                                   AS 物件数,
       (SELECT COUNT(*) FROM ExcutionBudget.ListOfMaterials x
         WHERE x.EntryId IN (SELECT new_entry FROM ExcutionBudget.tmp_copy_log y WHERE y.cid = l.cid)) AS 材料,
       (SELECT COUNT(*) FROM ExcutionBudget.ListOfExpences x
         WHERE x.EntryId IN (SELECT new_entry FROM ExcutionBudget.tmp_copy_log y WHERE y.cid = l.cid)) AS 経費,
       (SELECT COUNT(*) FROM ExcutionBudget.ListOfEstimationResults x
         WHERE x.EntryId IN (SELECT new_entry FROM ExcutionBudget.tmp_copy_log y WHERE y.cid = l.cid)) AS 見積結果,
       (SELECT COUNT(*) FROM ExcutionBudget.ListOfEstimates x
         WHERE x.EntryId IN (SELECT new_entry FROM ExcutionBudget.tmp_copy_log y WHERE y.cid = l.cid)) AS 見積
FROM ExcutionBudget.tmp_copy_log l
GROUP BY l.cid;


/* ============================================================================
   STEP 5-3 : 親子の整合性を確認する（★COMMIT の判断基準）
   ---------------------------------------------------------------------------
   子の CompanyId と、その EntryId が指す親の CompanyId が食い違う行を数える。
   ★ すべて 0 でなければ COMMIT せず ROLLBACK すること。
   ============================================================================ */
SELECT 'ListOfMaterials' AS tbl, COUNT(*) AS mismatched
  FROM ExcutionBudget.ListOfMaterials c
  JOIN ExcutionBudget.PropertyInfo   p ON p.EntryId = c.EntryId
 WHERE c.CompanyId <> p.CompanyId
UNION ALL
SELECT 'ListOfExpences', COUNT(*)
  FROM ExcutionBudget.ListOfExpences c
  JOIN ExcutionBudget.PropertyInfo   p ON p.EntryId = c.EntryId
 WHERE c.CompanyId <> p.CompanyId
UNION ALL
SELECT 'ListOfEstimationResults', COUNT(*)
  FROM ExcutionBudget.ListOfEstimationResults c
  JOIN ExcutionBudget.PropertyInfo   p ON p.EntryId = c.EntryId
 WHERE c.CompanyId <> p.CompanyId
UNION ALL
SELECT 'ListOfEstimates', COUNT(*)
  FROM ExcutionBudget.ListOfEstimates c
  JOIN ExcutionBudget.PropertyInfo   p ON p.EntryId = c.EntryId
 WHERE c.CompanyId <> p.CompanyId;


/* ============================================================================
   STEP 5-4 : 全体の件数を確認する
   ---------------------------------------------------------------------------
   各社が「元の件数 + PropertyInfo 4 / ListOfMaterials 260 / ListOfExpences 16 /
   ListOfEstimationResults 20 / ListOfEstimates 60」になっていれば成功
   ============================================================================ */
SELECT 'PropertyInfo' AS table_name, CompanyId, COUNT(*) AS cnt
  FROM ExcutionBudget.PropertyInfo
 WHERE CompanyId IN ('12345678','1','2','5','15','17','20') GROUP BY CompanyId
UNION ALL
SELECT 'ListOfMaterials', CompanyId, COUNT(*)
  FROM ExcutionBudget.ListOfMaterials
 WHERE CompanyId IN ('12345678','1','2','5','15','17','20') GROUP BY CompanyId
UNION ALL
SELECT 'ListOfExpences', CompanyId, COUNT(*)
  FROM ExcutionBudget.ListOfExpences
 WHERE CompanyId IN ('12345678','1','2','5','15','17','20') GROUP BY CompanyId
UNION ALL
SELECT 'ListOfEstimationResults', CompanyId, COUNT(*)
  FROM ExcutionBudget.ListOfEstimationResults
 WHERE CompanyId IN ('12345678','1','2','5','15','17','20') GROUP BY CompanyId
UNION ALL
SELECT 'ListOfEstimates', CompanyId, COUNT(*)
  FROM ExcutionBudget.ListOfEstimates
 WHERE CompanyId IN ('12345678','1','2','5','15','17','20') GROUP BY CompanyId
ORDER BY table_name, CompanyId;


/* ============================================================================
   STEP 5-5 : 問題なければ確定する
   ============================================================================ */
-- COMMIT;
-- ROLLBACK;


/* ============================================================================
   STEP 6 : 後片付け
   ---------------------------------------------------------------------------
   ★ tmp_copy_log は取り消しに使うため、業務確認が終わるまで残しておくこと
   ============================================================================ */
DROP PROCEDURE IF EXISTS ExcutionBudget.tmp_copy_property;
SET SQL_SAFE_UPDATES = 1;

-- 業務確認が終わったら
-- DROP TABLE ExcutionBudget.tmp_copy_log;


/* ============================================================================
   付録 : COMMIT 後に取り消す
   ---------------------------------------------------------------------------
   tmp_copy_log に記録した EntryId だけを消すので、既存データには影響しない。
   （tmp_copy_log を削除してしまった場合は STEP 0-2 のバックアップから戻す）
   ============================================================================ */
/*
SET SQL_SAFE_UPDATES = 0;
START TRANSACTION;

DELETE FROM ExcutionBudget.ListOfEstimates
 WHERE EntryId IN (SELECT new_entry FROM ExcutionBudget.tmp_copy_log);
DELETE FROM ExcutionBudget.ListOfEstimationResults
 WHERE EntryId IN (SELECT new_entry FROM ExcutionBudget.tmp_copy_log);
DELETE FROM ExcutionBudget.ListOfExpences
 WHERE EntryId IN (SELECT new_entry FROM ExcutionBudget.tmp_copy_log);
DELETE FROM ExcutionBudget.ListOfMaterials
 WHERE EntryId IN (SELECT new_entry FROM ExcutionBudget.tmp_copy_log);
DELETE FROM ExcutionBudget.PropertyInfo
 WHERE EntryId IN (SELECT new_entry FROM ExcutionBudget.tmp_copy_log);

-- 件数を確認してから
-- COMMIT;
-- ROLLBACK;
*/
