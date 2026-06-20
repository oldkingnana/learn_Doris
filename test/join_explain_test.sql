CREATE DATABASE IF NOT EXISTS join_explain_test;

USE join_explain_test;

DROP TABLE IF EXISTS user_profile;
DROP TABLE IF EXISTS order_snapshot;
DROP TABLE IF EXISTS user_behavior_detail;

-- ============================================================
-- Join + EXPLAIN 测试
--
-- 目标：
-- 1. 建几张更贴近真实业务分析的表。
-- 2. 用 Join 把用户画像、用户行为、订单快照关联起来。
-- 3. 用 EXPLAIN 观察 Doris 如何执行 Join。
--
-- 重点关注执行计划里的：
--   VOlapScanNode：扫描 Doris OLAP 表
--   HASH JOIN：哈希连接，也就是用哈希表做 Join
--   VAGGREGATE：聚合，比如 GROUP BY / COUNT / SUM
--   VSORT：排序，对应 ORDER BY
--   EXCHANGE：执行片段之间交换数据
-- ============================================================

-- ============================================================
-- user_profile：用户画像快照表
--
-- 这是分析用维表，不是业务系统里的用户主表。
-- 使用 UNIQUE KEY，因为同一个 user_id 只需要保留一份当前画像。
-- ============================================================

CREATE TABLE user_profile
(
    user_id INT,
    user_name VARCHAR(32),
    city VARCHAR(32),
    user_level VARCHAR(32),
    register_date DATE
)
UNIQUE KEY(user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 1
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- order_snapshot：订单当前状态快照表
--
-- 这是分析用订单快照，不是 OLTP 系统里的订单主表。
-- 使用 UNIQUE KEY，因为同一个 order_id 逻辑上只保留最新状态。
-- ============================================================

CREATE TABLE order_snapshot
(
    order_id BIGINT,
    user_id INT,
    order_status VARCHAR(32),
    order_amount DECIMAL(10, 2),
    order_time DATETIME
)
UNIQUE KEY(order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 1
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- user_behavior_detail：用户行为明细表
--
-- 使用 DUPLICATE KEY，因为同一个用户可以产生多条行为。
-- behavior_id 只是事件编号，不是唯一约束。
-- ============================================================

CREATE TABLE user_behavior_detail
(
    user_id INT,
    event_time DATETIME,
    behavior_id BIGINT,
    event_type VARCHAR(32),
    page_name VARCHAR(64),
    city VARCHAR(32),
    order_id BIGINT
)
DUPLICATE KEY(user_id, event_time)
DISTRIBUTED BY HASH(user_id) BUCKETS 1
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- 准备测试数据
-- ============================================================

INSERT INTO user_profile VALUES
(1001, 'Alice', 'Beijing', 'gold', '2026-01-01'),
(1002, 'Bob', 'Shanghai', 'silver', '2026-02-01'),
(1003, 'Cindy', 'Guangzhou', 'normal', '2026-03-01'),
(1004, 'David', 'Beijing', 'gold', '2026-04-01'),
(1005, 'Eva', 'Shenzhen', 'silver', '2026-05-01'),
(1006, 'Frank', 'Shanghai', 'normal', '2026-05-15'),
(1007, 'Grace', 'Beijing', 'normal', '2026-06-01');

INSERT INTO order_snapshot VALUES
(20001, 1001, 'paid', 58.50, '2026-06-20 09:05:18'),
(20002, 1002, 'paid', 76.00, '2026-06-20 10:18:01'),
(20003, 1004, 'paid', 42.00, '2026-06-20 12:10:09'),
(20004, 1005, 'paid', 93.80, '2026-06-20 13:39:45'),
(20005, 1007, 'paid', 35.90, '2026-06-20 15:50:10');

INSERT INTO user_behavior_detail VALUES
(1001, '2026-06-20 09:01:10', 1, 'search', 'home', 'Beijing', NULL),
(1001, '2026-06-20 09:02:33', 2, 'click', 'restaurant_detail', 'Beijing', NULL),
(1001, '2026-06-20 09:05:18', 3, 'order_submit', 'checkout', 'Beijing', 20001),
(1002, '2026-06-20 10:11:02', 4, 'search', 'home', 'Shanghai', NULL),
(1002, '2026-06-20 10:12:44', 5, 'click', 'restaurant_detail', 'Shanghai', NULL),
(1002, '2026-06-20 10:18:01', 6, 'order_submit', 'checkout', 'Shanghai', 20002),
(1003, '2026-06-20 11:20:50', 7, 'search', 'home', 'Guangzhou', NULL),
(1004, '2026-06-20 12:10:09', 8, 'order_submit', 'checkout', 'Beijing', 20003),
(1005, '2026-06-20 13:39:45', 9, 'order_submit', 'checkout', 'Shenzhen', 20004),
(1007, '2026-06-20 15:50:10', 10, 'order_submit', 'checkout', 'Beijing', 20005);

-- ============================================================
-- 查询 1：用户行为 Join 用户画像
--
-- 业务含义：
--   统计不同用户等级产生了多少行为。
--
-- 观察点：
--   EXPLAIN 里应该能看到 HASH JOIN。
--   因为有 GROUP BY，还应该能看到 VAGGREGATE。
-- ============================================================

USE join_explain_test;
EXPLAIN
SELECT
    p.user_level,
    COUNT(*) AS behavior_count
FROM user_behavior_detail AS b
JOIN user_profile AS p
    ON b.user_id = p.user_id
GROUP BY p.user_level
ORDER BY behavior_count DESC;

SELECT
    p.user_level,
    COUNT(*) AS behavior_count
FROM user_behavior_detail AS b
JOIN user_profile AS p
    ON b.user_id = p.user_id
GROUP BY p.user_level
ORDER BY behavior_count DESC;

-- ============================================================
-- 查询 2：用户行为 Join 订单快照
--
-- 业务含义：
--   只统计真正下单行为对应的订单金额。
--
-- 观察点：
--   Join 条件是 b.order_id = o.order_id。
--   b.order_id 中存在 NULL，只有能匹配订单的行为会被 INNER JOIN 保留。
-- ============================================================

EXPLAIN
SELECT
    b.city,
    COUNT(*) AS order_behavior_count,
    SUM(o.order_amount) AS total_order_amount
FROM user_behavior_detail AS b
JOIN order_snapshot AS o
    ON b.order_id = o.order_id
GROUP BY b.city
ORDER BY total_order_amount DESC;

SELECT
    b.city,
    COUNT(*) AS order_behavior_count,
    SUM(o.order_amount) AS total_order_amount
FROM user_behavior_detail AS b
JOIN order_snapshot AS o
    ON b.order_id = o.order_id
GROUP BY b.city
ORDER BY total_order_amount DESC;

-- ============================================================
-- 查询 3：三表 Join
--
-- 业务含义：
--   按用户等级统计订单金额。
--
-- 观察点：
--   这里有两次 Join：
--     行为表 Join 用户画像表
--     行为表 Join 订单快照表
--   EXPLAIN 里可能出现多个 HASH JOIN。
-- ============================================================

EXPLAIN
SELECT
    p.user_level,
    COUNT(*) AS order_count,
    SUM(o.order_amount) AS total_order_amount
FROM user_behavior_detail AS b
JOIN user_profile AS p
    ON b.user_id = p.user_id
JOIN order_snapshot AS o
    ON b.order_id = o.order_id
WHERE b.event_type = 'order_submit'
GROUP BY p.user_level
ORDER BY total_order_amount DESC;

SELECT
    p.user_level,
    COUNT(*) AS order_count,
    SUM(o.order_amount) AS total_order_amount
FROM user_behavior_detail AS b
JOIN user_profile AS p
    ON b.user_id = p.user_id
JOIN order_snapshot AS o
    ON b.order_id = o.order_id
WHERE b.event_type = 'order_submit'
GROUP BY p.user_level
ORDER BY total_order_amount DESC;
