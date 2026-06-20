-- ============================================================
-- Query Profile 观察测试
--
-- 使用方式：
--   1. 在同一个 mariadb / DBUI 连接里连续执行。
--   2. 先执行 SET enable_profile = true。
--   3. 每跑完一条核心查询，再执行 SHOW QUERY PROFILE\G。
--   4. 拿到 Profile ID 后，可以去 WebUI 里点开看详细执行树。
--
-- 为什么单独建这个文件：
--   EXPLAIN 看的是“计划怎么跑”。
--   Query Profile 看的是“实际跑成什么样”。
--
-- 注意：
--   如果同一条 SQL 重复执行，Doris 可能命中 SQL Cache。
--   命中缓存后，Profile 里可能看不到真实扫描、调度、Exchange 等细节。
--   所以下面的查询都带了 run_tag 常量。
--   如果你重复测试，可以把 profile_run_01 改成 profile_run_02。
-- ============================================================

CREATE DATABASE IF NOT EXISTS profile_observe_test;

USE profile_observe_test;

DROP TABLE IF EXISTS behavior_fact_profile;
DROP TABLE IF EXISTS user_dim_profile;

-- ============================================================
-- user_dim_profile：用户画像维表
--
-- 这是小表，用于观察 Join 时 Doris 是否选择 Broadcast Join。
-- UNIQUE KEY 表示同一个 user_id 只保留一份画像。
-- ============================================================

CREATE TABLE user_dim_profile
(
    user_id INT,
    user_name VARCHAR(32),
    city VARCHAR(32),
    user_level VARCHAR(32)
)
UNIQUE KEY(user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 6
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- behavior_fact_profile：用户行为事实表
--
-- 这是明细表，用于模拟日志/行为流水。
-- DUPLICATE KEY 表示保留每一条行为明细，不按主键覆盖。
--
-- Key 列必须是字段列表的有序前缀。
-- 所以 event_date、user_id、event_time 放在最前面。
-- ============================================================

CREATE TABLE behavior_fact_profile
(
    event_date DATE,
    user_id INT,
    event_time DATETIME,
    behavior_id BIGINT,
    event_type VARCHAR(32),
    city VARCHAR(32),
    page_name VARCHAR(64),
    amount DECIMAL(10, 2)
)
DUPLICATE KEY(event_date, user_id, event_time)
DISTRIBUTED BY HASH(user_id) BUCKETS 6
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- 准备维表数据
-- ============================================================

INSERT INTO user_dim_profile VALUES
(1001, 'Alice', 'Beijing', 'gold'),
(1002, 'Bob', 'Shanghai', 'silver'),
(1003, 'Cindy', 'Guangzhou', 'normal'),
(1004, 'David', 'Beijing', 'gold'),
(1005, 'Eva', 'Shenzhen', 'silver'),
(1006, 'Frank', 'Shanghai', 'normal'),
(1007, 'Grace', 'Beijing', 'normal'),
(1008, 'Helen', 'Hangzhou', 'gold'),
(1009, 'Ian', 'Chengdu', 'silver'),
(1010, 'Jane', 'Wuhan', 'normal'),
(1011, 'Ken', 'Nanjing', 'gold'),
(1012, 'Lily', 'Suzhou', 'silver');

-- ============================================================
-- 准备事实表数据
--
-- 这里故意让 Beijing 的下单记录更多一点。
-- 后面看 Profile 时，可以观察局部聚合、Hash 分发和全局聚合。
-- ============================================================

INSERT INTO behavior_fact_profile VALUES
('2026-06-21', 1001, '2026-06-21 09:00:01', 1, 'search', 'Beijing', 'home', 0.00),
('2026-06-21', 1001, '2026-06-21 09:03:10', 2, 'order_submit', 'Beijing', 'checkout', 58.50),
('2026-06-21', 1002, '2026-06-21 09:10:21', 3, 'search', 'Shanghai', 'home', 0.00),
('2026-06-21', 1002, '2026-06-21 09:15:45', 4, 'order_submit', 'Shanghai', 'checkout', 76.00),
('2026-06-21', 1003, '2026-06-21 10:01:11', 5, 'click', 'Guangzhou', 'coupon_page', 0.00),
('2026-06-21', 1004, '2026-06-21 10:20:39', 6, 'order_submit', 'Beijing', 'checkout', 42.00),
('2026-06-21', 1005, '2026-06-21 11:02:00', 7, 'search', 'Shenzhen', 'home', 0.00),
('2026-06-21', 1005, '2026-06-21 11:08:14', 8, 'order_submit', 'Shenzhen', 'checkout', 93.80),
('2026-06-21', 1006, '2026-06-21 11:40:55', 9, 'click', 'Shanghai', 'restaurant_detail', 0.00),
('2026-06-21', 1007, '2026-06-21 12:00:10', 10, 'order_submit', 'Beijing', 'checkout', 35.90),
('2026-06-21', 1008, '2026-06-21 12:30:31', 11, 'order_submit', 'Hangzhou', 'checkout', 66.60),
('2026-06-21', 1009, '2026-06-21 13:01:02', 12, 'search', 'Chengdu', 'home', 0.00),
('2026-06-21', 1009, '2026-06-21 13:03:22', 13, 'order_submit', 'Chengdu', 'checkout', 88.80),
('2026-06-21', 1010, '2026-06-21 13:30:00', 14, 'click', 'Wuhan', 'restaurant_detail', 0.00),
('2026-06-21', 1011, '2026-06-21 14:00:01', 15, 'order_submit', 'Nanjing', 'checkout', 102.40),
('2026-06-21', 1012, '2026-06-21 14:20:44', 16, 'order_submit', 'Suzhou', 'checkout', 79.90),
('2026-06-22', 1001, '2026-06-22 09:00:01', 17, 'order_submit', 'Beijing', 'checkout', 61.20),
('2026-06-22', 1004, '2026-06-22 09:30:11', 18, 'order_submit', 'Beijing', 'checkout', 49.90),
('2026-06-22', 1007, '2026-06-22 10:10:21', 19, 'order_submit', 'Beijing', 'checkout', 28.80),
('2026-06-22', 1002, '2026-06-22 10:40:00', 20, 'order_submit', 'Shanghai', 'checkout', 81.30),
('2026-06-22', 1008, '2026-06-22 11:00:22', 21, 'search', 'Hangzhou', 'home', 0.00),
('2026-06-22', 1011, '2026-06-22 11:30:45', 22, 'click', 'Nanjing', 'coupon_page', 0.00);

-- ============================================================
-- 观察 0：确认 Tablet 是否分布到多个 BE
--
-- 重点看：
--   1. SHOW BACKENDS 里的 TabletNum。
--   2. SHOW TABLETS 里的 BackendId。
-- ============================================================

SHOW BACKENDS\G

SHOW TABLETS FROM profile_observe_test.behavior_fact_profile\G

-- ============================================================
-- 观察 1：先看 EXPLAIN，再看 Query Profile
--
-- 业务含义：
--   统计 2026-06-21 每个城市的下单数和下单金额。
--
-- EXPLAIN 重点：
--   1. OLAP_SCAN / PhysicalOlapScan：扫描 OLAP 表。
--   2. HASH AGGREGATE：聚合。
--   3. EXCHANGE / PhysicalDistribute：数据交换。
--   4. SORT / PhysicalQuickSort：排序。
--
-- Profile 重点：
--   1. ScanRows：实际扫描了多少行。
--   2. RowsReturned：每个节点返回了多少行。
--   3. Exchange 相关耗时：数据交换成本。
--   4. PeakMemoryUsage：峰值内存。
-- ============================================================

SET enable_profile = true;

EXPLAIN
SELECT
    'profile_run_01' AS run_tag,
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_fact_profile
WHERE event_date = '2026-06-21'
  AND event_type = 'order_submit'
GROUP BY city
ORDER BY total_amount DESC;

SELECT
    'profile_run_01' AS run_tag,
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_fact_profile
WHERE event_date = '2026-06-21'
  AND event_type = 'order_submit'
GROUP BY city
ORDER BY total_amount DESC;

SHOW QUERY PROFILE\G

-- ============================================================
-- 观察 2：Join + 聚合
--
-- 业务含义：
--   把行为事实表和用户画像表 Join 起来，按用户等级统计下单金额。
--
-- 观察点：
--   1. 如果用户画像表很小，优化器可能选择 Broadcast Join。
--   2. Join 后还会继续做局部聚合、Hash 分发、全局聚合、排序。
--   3. WebUI 的 PhysicalPlan 里可以找 HashJoin / Distribute / Aggregate。
-- ============================================================

EXPLAIN
SELECT
    'profile_run_02' AS run_tag,
    u.user_level,
    COUNT(*) AS order_count,
    SUM(b.amount) AS total_amount
FROM behavior_fact_profile AS b
JOIN user_dim_profile AS u
    ON b.user_id = u.user_id
WHERE b.event_date = '2026-06-21'
  AND b.event_type = 'order_submit'
GROUP BY u.user_level
ORDER BY total_amount DESC;

SELECT
    'profile_run_02' AS run_tag,
    u.user_level,
    COUNT(*) AS order_count,
    SUM(b.amount) AS total_amount
FROM behavior_fact_profile AS b
JOIN user_dim_profile AS u
    ON b.user_id = u.user_id
WHERE b.event_date = '2026-06-21'
  AND b.event_type = 'order_submit'
GROUP BY u.user_level
ORDER BY total_amount DESC;

SHOW QUERY PROFILE\G

-- ============================================================
-- 观察 3：换一天数据，尽量避免重复 SQL 命中缓存
--
-- 业务含义：
--   同样的统计逻辑，但查询 2026-06-22。
--
-- 为什么这样做：
--   如果你直接重复执行观察 1 的 SQL，可能命中 SQL Cache。
--   换日期、换 run_tag 后，SQL 文本和数据范围都变了，更适合观察新 Profile。
-- ============================================================

EXPLAIN
SELECT
    'profile_run_03' AS run_tag,
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_fact_profile
WHERE event_date = '2026-06-22'
  AND event_type = 'order_submit'
GROUP BY city
ORDER BY total_amount DESC;

SELECT
    'profile_run_03' AS run_tag,
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_fact_profile
WHERE event_date = '2026-06-22'
  AND event_type = 'order_submit'
GROUP BY city
ORDER BY total_amount DESC;

SHOW QUERY PROFILE\G

-- ============================================================
-- 观察 4：可选，手动制造一次新数据版本
--
-- 如果你发现 WebUI 里仍然显示 Is Cached: Yes，
-- 可以先插入一条新数据，让表的数据版本发生变化，再执行下一条查询。
--
-- 注意：
--   这段会真的写入一行数据。
--   如果你只想观察前面的 Profile，可以先不执行这一段。
-- ============================================================

INSERT INTO behavior_fact_profile VALUES
('2026-06-23', 1001, '2026-06-23 09:00:01', 23, 'order_submit', 'Beijing', 'checkout', 77.70);

SELECT
    'profile_run_04_after_insert' AS run_tag,
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_fact_profile
WHERE event_date = '2026-06-23'
  AND event_type = 'order_submit'
GROUP BY city
ORDER BY total_amount DESC;

SHOW QUERY PROFILE\G
