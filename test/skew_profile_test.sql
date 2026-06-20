-- ============================================================
-- 数据倾斜 Query Profile 测试
--
-- 使用方式：
--   1. 在同一个 mariadb / DBUI 连接里执行。
--   2. 每条核心查询执行前确保 SET enable_profile = true。
--   3. 每跑完一条核心查询，执行 SHOW QUERY PROFILE\G。
--   4. 拿 Profile ID 去 WebUI 打开详细 Profile。
--
-- 这组测试想观察两个问题：
--   1. 如果表按 city 分桶，而大量数据都是 Beijing，会不会导致扫描倾斜。
--   2. 如果 GROUP BY city，而 Beijing 特别多，会不会让聚合/Exchange 更集中。
--
-- Profile 重点看：
--   OLAP_SCAN_OPERATOR:
--     ScanRows / RowsProduced 的 avg、max、min 是否差距很大。
--
--   DATA_STREAM_SINK_OPERATOR / EXCHANGE_OPERATOR:
--     InputRows / RowsProduced 的 avg、max、min 是否差距很大。
--
--   AGGREGATION_SINK_OPERATOR:
--     InputRows 的 max 是否明显大于 avg/min。
--
-- 读法：
--   max 远大于 avg/min，通常说明某些 instance 明显更忙，可能存在倾斜。
-- ============================================================

CREATE DATABASE IF NOT EXISTS skew_profile_test;

USE skew_profile_test;

DROP TABLE IF EXISTS behavior_by_city;
DROP TABLE IF EXISTS behavior_by_user;

-- ============================================================
-- 表 1：按 city 分桶
--
-- 因为大多数数据都是 Beijing，所以按 city 分桶会让 Beijing 相关数据
-- 更容易集中到少数 Tablet / BE 上。
--
-- 这个表用于观察“存储分布导致的扫描倾斜”。
-- ============================================================

CREATE TABLE behavior_by_city
(
    event_date DATE,
    city VARCHAR(32),
    user_id INT,
    event_time DATETIME,
    behavior_id BIGINT,
    event_type VARCHAR(32),
    amount DECIMAL(10, 2)
)
DUPLICATE KEY(event_date, city, user_id, event_time)
DISTRIBUTED BY HASH(city) BUCKETS 6
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- 表 2：按 user_id 分桶
--
-- user_id 比 city 更分散，所以同样的数据按 user_id 分桶，
-- 通常会比按 city 分桶更均匀。
--
-- 这个表用于和 behavior_by_city 做对照。
-- ============================================================

CREATE TABLE behavior_by_user
(
    event_date DATE,
    user_id INT,
    event_time DATETIME,
    behavior_id BIGINT,
    city VARCHAR(32),
    event_type VARCHAR(32),
    amount DECIMAL(10, 2)
)
DUPLICATE KEY(event_date, user_id, event_time)
DISTRIBUTED BY HASH(user_id) BUCKETS 6
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- 准备倾斜数据
--
-- 设计：
--   30 条 Beijing 下单数据
--   12 条其他城市下单数据
--
-- 这样 city 维度明显倾斜，但 user_id 仍然相对分散。
-- ============================================================

INSERT INTO behavior_by_city VALUES
('2026-06-24', 'Beijing', 1001, '2026-06-24 09:00:01', 1, 'order_submit', 31.10),
('2026-06-24', 'Beijing', 1002, '2026-06-24 09:01:01', 2, 'order_submit', 32.20),
('2026-06-24', 'Beijing', 1003, '2026-06-24 09:02:01', 3, 'order_submit', 33.30),
('2026-06-24', 'Beijing', 1004, '2026-06-24 09:03:01', 4, 'order_submit', 34.40),
('2026-06-24', 'Beijing', 1005, '2026-06-24 09:04:01', 5, 'order_submit', 35.50),
('2026-06-24', 'Beijing', 1006, '2026-06-24 09:05:01', 6, 'order_submit', 36.60),
('2026-06-24', 'Beijing', 1007, '2026-06-24 09:06:01', 7, 'order_submit', 37.70),
('2026-06-24', 'Beijing', 1008, '2026-06-24 09:07:01', 8, 'order_submit', 38.80),
('2026-06-24', 'Beijing', 1009, '2026-06-24 09:08:01', 9, 'order_submit', 39.90),
('2026-06-24', 'Beijing', 1010, '2026-06-24 09:09:01', 10, 'order_submit', 40.10),
('2026-06-24', 'Beijing', 1011, '2026-06-24 09:10:01', 11, 'order_submit', 41.20),
('2026-06-24', 'Beijing', 1012, '2026-06-24 09:11:01', 12, 'order_submit', 42.30),
('2026-06-24', 'Beijing', 1013, '2026-06-24 09:12:01', 13, 'order_submit', 43.40),
('2026-06-24', 'Beijing', 1014, '2026-06-24 09:13:01', 14, 'order_submit', 44.50),
('2026-06-24', 'Beijing', 1015, '2026-06-24 09:14:01', 15, 'order_submit', 45.60),
('2026-06-24', 'Beijing', 1016, '2026-06-24 09:15:01', 16, 'order_submit', 46.70),
('2026-06-24', 'Beijing', 1017, '2026-06-24 09:16:01', 17, 'order_submit', 47.80),
('2026-06-24', 'Beijing', 1018, '2026-06-24 09:17:01', 18, 'order_submit', 48.90),
('2026-06-24', 'Beijing', 1019, '2026-06-24 09:18:01', 19, 'order_submit', 49.10),
('2026-06-24', 'Beijing', 1020, '2026-06-24 09:19:01', 20, 'order_submit', 50.20),
('2026-06-24', 'Beijing', 1021, '2026-06-24 09:20:01', 21, 'order_submit', 51.30),
('2026-06-24', 'Beijing', 1022, '2026-06-24 09:21:01', 22, 'order_submit', 52.40),
('2026-06-24', 'Beijing', 1023, '2026-06-24 09:22:01', 23, 'order_submit', 53.50),
('2026-06-24', 'Beijing', 1024, '2026-06-24 09:23:01', 24, 'order_submit', 54.60),
('2026-06-24', 'Beijing', 1025, '2026-06-24 09:24:01', 25, 'order_submit', 55.70),
('2026-06-24', 'Beijing', 1026, '2026-06-24 09:25:01', 26, 'order_submit', 56.80),
('2026-06-24', 'Beijing', 1027, '2026-06-24 09:26:01', 27, 'order_submit', 57.90),
('2026-06-24', 'Beijing', 1028, '2026-06-24 09:27:01', 28, 'order_submit', 58.10),
('2026-06-24', 'Beijing', 1029, '2026-06-24 09:28:01', 29, 'order_submit', 59.20),
('2026-06-24', 'Beijing', 1030, '2026-06-24 09:29:01', 30, 'order_submit', 60.30),
('2026-06-24', 'Shanghai', 1031, '2026-06-24 10:00:01', 31, 'order_submit', 61.10),
('2026-06-24', 'Shanghai', 1032, '2026-06-24 10:01:01', 32, 'order_submit', 62.20),
('2026-06-24', 'Shenzhen', 1033, '2026-06-24 10:02:01', 33, 'order_submit', 63.30),
('2026-06-24', 'Shenzhen', 1034, '2026-06-24 10:03:01', 34, 'order_submit', 64.40),
('2026-06-24', 'Hangzhou', 1035, '2026-06-24 10:04:01', 35, 'order_submit', 65.50),
('2026-06-24', 'Hangzhou', 1036, '2026-06-24 10:05:01', 36, 'order_submit', 66.60),
('2026-06-24', 'Nanjing', 1037, '2026-06-24 10:06:01', 37, 'order_submit', 67.70),
('2026-06-24', 'Nanjing', 1038, '2026-06-24 10:07:01', 38, 'order_submit', 68.80),
('2026-06-24', 'Chengdu', 1039, '2026-06-24 10:08:01', 39, 'order_submit', 69.90),
('2026-06-24', 'Chengdu', 1040, '2026-06-24 10:09:01', 40, 'order_submit', 70.10),
('2026-06-24', 'Wuhan', 1041, '2026-06-24 10:10:01', 41, 'order_submit', 71.20),
('2026-06-24', 'Wuhan', 1042, '2026-06-24 10:11:01', 42, 'order_submit', 72.30);

-- 同一批数据，写入按 user_id 分桶的表。
INSERT INTO behavior_by_user VALUES
('2026-06-24', 1001, '2026-06-24 09:00:01', 1, 'Beijing', 'order_submit', 31.10),
('2026-06-24', 1002, '2026-06-24 09:01:01', 2, 'Beijing', 'order_submit', 32.20),
('2026-06-24', 1003, '2026-06-24 09:02:01', 3, 'Beijing', 'order_submit', 33.30),
('2026-06-24', 1004, '2026-06-24 09:03:01', 4, 'Beijing', 'order_submit', 34.40),
('2026-06-24', 1005, '2026-06-24 09:04:01', 5, 'Beijing', 'order_submit', 35.50),
('2026-06-24', 1006, '2026-06-24 09:05:01', 6, 'Beijing', 'order_submit', 36.60),
('2026-06-24', 1007, '2026-06-24 09:06:01', 7, 'Beijing', 'order_submit', 37.70),
('2026-06-24', 1008, '2026-06-24 09:07:01', 8, 'Beijing', 'order_submit', 38.80),
('2026-06-24', 1009, '2026-06-24 09:08:01', 9, 'Beijing', 'order_submit', 39.90),
('2026-06-24', 1010, '2026-06-24 09:09:01', 10, 'Beijing', 'order_submit', 40.10),
('2026-06-24', 1011, '2026-06-24 09:10:01', 11, 'Beijing', 'order_submit', 41.20),
('2026-06-24', 1012, '2026-06-24 09:11:01', 12, 'Beijing', 'order_submit', 42.30),
('2026-06-24', 1013, '2026-06-24 09:12:01', 13, 'Beijing', 'order_submit', 43.40),
('2026-06-24', 1014, '2026-06-24 09:13:01', 14, 'Beijing', 'order_submit', 44.50),
('2026-06-24', 1015, '2026-06-24 09:14:01', 15, 'Beijing', 'order_submit', 45.60),
('2026-06-24', 1016, '2026-06-24 09:15:01', 16, 'Beijing', 'order_submit', 46.70),
('2026-06-24', 1017, '2026-06-24 09:16:01', 17, 'Beijing', 'order_submit', 47.80),
('2026-06-24', 1018, '2026-06-24 09:17:01', 18, 'Beijing', 'order_submit', 48.90),
('2026-06-24', 1019, '2026-06-24 09:18:01', 19, 'Beijing', 'order_submit', 49.10),
('2026-06-24', 1020, '2026-06-24 09:19:01', 20, 'Beijing', 'order_submit', 50.20),
('2026-06-24', 1021, '2026-06-24 09:20:01', 21, 'Beijing', 'order_submit', 51.30),
('2026-06-24', 1022, '2026-06-24 09:21:01', 22, 'Beijing', 'order_submit', 52.40),
('2026-06-24', 1023, '2026-06-24 09:22:01', 23, 'Beijing', 'order_submit', 53.50),
('2026-06-24', 1024, '2026-06-24 09:23:01', 24, 'Beijing', 'order_submit', 54.60),
('2026-06-24', 1025, '2026-06-24 09:24:01', 25, 'Beijing', 'order_submit', 55.70),
('2026-06-24', 1026, '2026-06-24 09:25:01', 26, 'Beijing', 'order_submit', 56.80),
('2026-06-24', 1027, '2026-06-24 09:26:01', 27, 'Beijing', 'order_submit', 57.90),
('2026-06-24', 1028, '2026-06-24 09:27:01', 28, 'Beijing', 'order_submit', 58.10),
('2026-06-24', 1029, '2026-06-24 09:28:01', 29, 'Beijing', 'order_submit', 59.20),
('2026-06-24', 1030, '2026-06-24 09:29:01', 30, 'Beijing', 'order_submit', 60.30),
('2026-06-24', 1031, '2026-06-24 10:00:01', 31, 'Shanghai', 'order_submit', 61.10),
('2026-06-24', 1032, '2026-06-24 10:01:01', 32, 'Shanghai', 'order_submit', 62.20),
('2026-06-24', 1033, '2026-06-24 10:02:01', 33, 'Shenzhen', 'order_submit', 63.30),
('2026-06-24', 1034, '2026-06-24 10:03:01', 34, 'Shenzhen', 'order_submit', 64.40),
('2026-06-24', 1035, '2026-06-24 10:04:01', 35, 'Hangzhou', 'order_submit', 65.50),
('2026-06-24', 1036, '2026-06-24 10:05:01', 36, 'Hangzhou', 'order_submit', 66.60),
('2026-06-24', 1037, '2026-06-24 10:06:01', 37, 'Nanjing', 'order_submit', 67.70),
('2026-06-24', 1038, '2026-06-24 10:07:01', 38, 'Nanjing', 'order_submit', 68.80),
('2026-06-24', 1039, '2026-06-24 10:08:01', 39, 'Chengdu', 'order_submit', 69.90),
('2026-06-24', 1040, '2026-06-24 10:09:01', 40, 'Chengdu', 'order_submit', 70.10),
('2026-06-24', 1041, '2026-06-24 10:10:01', 41, 'Wuhan', 'order_submit', 71.20),
('2026-06-24', 1042, '2026-06-24 10:11:01', 42, 'Wuhan', 'order_submit', 72.30);

-- ============================================================
-- 观察 0：确认 Tablet 分布
--
-- 重点：
--   SHOW TABLETS 里看 TabletId 和 BackendId。
--   如果 behavior_by_city 的某些 Tablet RowCount 明显更高，
--   就说明按 city 分桶已经造成存储侧倾斜。
-- ============================================================

SHOW BACKENDS\G

SHOW TABLETS FROM skew_profile_test.behavior_by_city\G

SHOW TABLETS FROM skew_profile_test.behavior_by_user\G

-- ============================================================
-- 观察 1：按 city 分桶，并且按 city 聚合
--
-- 这是最容易倾斜的一组：
--   存储按 city 分桶，Beijing 很集中。
--   聚合也按 city 分组，Beijing 最终也会汇到同一个 group key。
--
-- Profile 重点：
--   OLAP_SCAN_OPERATOR 的 ScanRows max/min。
--   AGGREGATION_SINK_OPERATOR 的 InputRows max/min。
-- ============================================================

SET enable_profile = true;

EXPLAIN
SELECT
    'skew_run_01_by_city_group_city' AS run_tag,
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_by_city
WHERE event_date = '2026-06-24'
GROUP BY city
ORDER BY order_count DESC;

SELECT
    'skew_run_01_by_city_group_city' AS run_tag,
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_by_city
WHERE event_date = '2026-06-24'
GROUP BY city
ORDER BY order_count DESC;

SHOW QUERY PROFILE\G

-- ============================================================
-- 观察 2：按 user_id 分桶，但仍然按 city 聚合
--
-- 这组用于和观察 1 对比：
--   存储分布更均匀，因为 user_id 比 city 更分散。
--   但 GROUP BY city 仍然是低基数字段，最终聚合仍可能集中。
--
-- Profile 重点：
--   OLAP_SCAN_OPERATOR 的 ScanRows max/min 应该比观察 1 更均匀。
--   AGGREGATION_SINK_OPERATOR 仍可能体现 city 聚合的集中。
-- ============================================================

EXPLAIN
SELECT
    'skew_run_02_by_user_group_city' AS run_tag,
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_by_user
WHERE event_date = '2026-06-24'
GROUP BY city
ORDER BY order_count DESC;

SELECT
    'skew_run_02_by_user_group_city' AS run_tag,
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_by_user
WHERE event_date = '2026-06-24'
GROUP BY city
ORDER BY order_count DESC;

SHOW QUERY PROFILE\G

-- ============================================================
-- 观察 3：按 user_id 分桶，并且按 user_id 聚合
--
-- 这是相对均匀的一组：
--   存储按 user_id 分散。
--   聚合也按 user_id 分组。
--
-- Profile 重点：
--   ScanRows、RowsProduced、InputRows 的 avg/max/min 应该更接近。
--   和观察 1 对比，可以更直观看到倾斜和均匀的差别。
-- ============================================================

EXPLAIN
SELECT
    'skew_run_03_by_user_group_user' AS run_tag,
    user_id,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_by_user
WHERE event_date = '2026-06-24'
GROUP BY user_id
ORDER BY user_id;

SELECT
    'skew_run_03_by_user_group_user' AS run_tag,
    user_id,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_by_user
WHERE event_date = '2026-06-24'
GROUP BY user_id
ORDER BY user_id;

SHOW QUERY PROFILE\G
