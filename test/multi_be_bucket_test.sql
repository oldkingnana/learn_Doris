CREATE DATABASE IF NOT EXISTS multi_be_test;

USE multi_be_test;

DROP TABLE IF EXISTS user_profile_bucket;
DROP TABLE IF EXISTS behavior_bucket_test;

-- ============================================================
-- 多 BE + 多 Bucket 测试
--
-- 前提：
--   本地已经启动 3 个 BE：
--     127.0.0.1:9050
--     127.0.0.1:9150
--     127.0.0.1:9250
--
-- 目标：
--   1. 创建 BUCKETS > 1 的表，让数据可以分散到多个 Tablet。
--   2. 观察多个 BE 的 TabletNum 是否增加。
--   3. 用 EXPLAIN 观察查询是否可能由多个 BE 参与。
--
-- 注意：
--   replication_num = 1 表示每个 Tablet 只有一份副本。
--   这样更容易观察 Tablet 被分散到不同 BE 上。
-- ============================================================

-- ============================================================
-- 用户画像表
--
-- 使用 UNIQUE KEY，表示同一个 user_id 只保留一份当前画像。
-- BUCKETS 6 表示按照 user_id 哈希分成 6 个桶。
-- 在 3 个 BE 存活的情况下，这些 Tablet 有机会分散到多个 BE。
-- ============================================================

CREATE TABLE user_profile_bucket
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
-- 用户行为明细表
--
-- 使用 DUPLICATE KEY，保留所有行为明细。
-- Key 列必须是字段列表的有序前缀，所以 user_id 和 event_time 放在最前面。
-- ============================================================

CREATE TABLE behavior_bucket_test
(
    user_id INT,
    event_time DATETIME,
    behavior_id BIGINT,
    event_type VARCHAR(32),
    city VARCHAR(32),
    amount DECIMAL(10, 2)
)
DUPLICATE KEY(user_id, event_time)
DISTRIBUTED BY HASH(user_id) BUCKETS 6
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- 准备测试数据
-- ============================================================

INSERT INTO user_profile_bucket VALUES
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

INSERT INTO behavior_bucket_test VALUES
(1001, '2026-06-21 09:00:01', 1, 'search', 'Beijing', 0.00),
(1001, '2026-06-21 09:03:10', 2, 'order_submit', 'Beijing', 58.50),
(1002, '2026-06-21 09:10:21', 3, 'search', 'Shanghai', 0.00),
(1002, '2026-06-21 09:15:45', 4, 'order_submit', 'Shanghai', 76.00),
(1003, '2026-06-21 10:01:11', 5, 'click', 'Guangzhou', 0.00),
(1004, '2026-06-21 10:20:39', 6, 'order_submit', 'Beijing', 42.00),
(1005, '2026-06-21 11:02:00', 7, 'search', 'Shenzhen', 0.00),
(1005, '2026-06-21 11:08:14', 8, 'order_submit', 'Shenzhen', 93.80),
(1006, '2026-06-21 11:40:55', 9, 'click', 'Shanghai', 0.00),
(1007, '2026-06-21 12:00:10', 10, 'order_submit', 'Beijing', 35.90),
(1008, '2026-06-21 12:30:31', 11, 'order_submit', 'Hangzhou', 66.60),
(1009, '2026-06-21 13:01:02', 12, 'search', 'Chengdu', 0.00),
(1009, '2026-06-21 13:03:22', 13, 'order_submit', 'Chengdu', 88.80),
(1010, '2026-06-21 13:30:00', 14, 'click', 'Wuhan', 0.00),
(1011, '2026-06-21 14:00:01', 15, 'order_submit', 'Nanjing', 102.40),
(1012, '2026-06-21 14:20:44', 16, 'order_submit', 'Suzhou', 79.90);

-- ============================================================
-- 观察 1：查看 3 个 BE 的 Tablet 数量
--
-- 这条语句用于观察新表建好并写入后，Tablet 是否分散到了多个 BE。
-- 重点看 SHOW BACKENDS 结果里的 TabletNum。
-- ============================================================

SHOW BACKENDS\G

-- ============================================================
-- 观察 2：普通聚合查询
--
-- 业务含义：
--   按城市统计行为数和下单金额。
--
-- EXPLAIN 观察点：
--   1. VOlapScanNode 中 tablets 是否大于 1。
--   2. numNodes 是否可能大于 1。
--   3. 是否出现两阶段 VAGGREGATE。
--   4. 是否出现 EXCHANGE。
-- ============================================================

USE multi_be_test;
EXPLAIN
SELECT
    city,
    COUNT(*) AS behavior_count,
    SUM(amount) AS total_amount
FROM behavior_bucket_test
GROUP BY city
ORDER BY total_amount DESC;

SELECT
    city,
    COUNT(*) AS behavior_count,
    SUM(amount) AS total_amount
FROM behavior_bucket_test
GROUP BY city
ORDER BY total_amount DESC;

-- ============================================================
-- 观察 3：Join 查询
--
-- 业务含义：
--   行为表 Join 用户画像表，按用户等级统计行为数和金额。
--
-- EXPLAIN 观察点：
--   1. 是否出现 HASH JOIN。
--   2. Join 类型可能是 BROADCAST，也可能随统计信息和表规模变化。
--   3. Join 后仍然会进入聚合、Exchange、排序等阶段。
-- ============================================================

EXPLAIN
SELECT
    p.user_level,
    COUNT(*) AS behavior_count,
    SUM(b.amount) AS total_amount
FROM behavior_bucket_test AS b
JOIN user_profile_bucket AS p
    ON b.user_id = p.user_id
GROUP BY p.user_level
ORDER BY total_amount DESC;

SELECT
    p.user_level,
    COUNT(*) AS behavior_count,
    SUM(b.amount) AS total_amount
FROM behavior_bucket_test AS b
JOIN user_profile_bucket AS p
    ON b.user_id = p.user_id
GROUP BY p.user_level
ORDER BY total_amount DESC;

-- ============================================================
-- 观察 4：只看下单行为
--
-- 业务含义：
--   过滤 event_type = 'order_submit' 后，再按城市聚合。
--
-- EXPLAIN 观察点：
--   VOlapScanNode 中可能出现 PREDICATES，表示扫描阶段带过滤条件。
-- ============================================================

EXPLAIN
SELECT
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_bucket_test
WHERE event_type = 'order_submit'
GROUP BY city
ORDER BY total_amount DESC;

SET enable_profile = true;
USE multi_be_test;
SELECT
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_bucket_test
WHERE event_type = 'order_submit'
GROUP BY city
ORDER BY total_amount DESC;

SHOW QUERY PROFILE\G
show query profile;

SHOW TABLETS FROM multi_be_test.behavior_bucket_test\G


SET enable_profile = true;
USE multi_be_test;
SELECT
    city,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM behavior_bucket_test
WHERE event_type = 'order_submit'
GROUP BY city
ORDER BY total_amount DESC;

SHOW QUERY PROFILE\G
