CREATE DATABASE IF NOT EXISTS table_model_test;

USE table_model_test;

DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS user_behaviors;
DROP TABLE IF EXISTS order_operations;
DROP TABLE IF EXISTS street_order_data;
DROP TABLE IF EXISTS city_order_data;

-- ============================================================
-- 1. UNIQUE KEY：当前状态表
--    相同 Key 的数据在逻辑上只保留最新一行。
-- ============================================================

CREATE TABLE users
(
    user_id INT,
    user_name VARCHAR(32),
    city VARCHAR(32)
)
UNIQUE KEY(user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 1
PROPERTIES
(
    "replication_num" = "1"
);

CREATE TABLE orders
(
    order_id INT,
    user_id INT,
    amount DECIMAL(10, 2),
    order_date DATE,
    order_status VARCHAR(32)
)
UNIQUE KEY(order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 1
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- 2. DUPLICATE KEY：事件明细表
--    相同 Key 可以出现多次，Doris 会保留所有明细行。
-- ============================================================

CREATE TABLE user_behaviors
(
    user_id INT,
    query VARCHAR(128),
    user_click_on VARCHAR(128),
    purchase VARCHAR(128),
    order_id INT,
    behavior_date DATE
)
DUPLICATE KEY(user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 1
PROPERTIES
(
    "replication_num" = "1"
);

CREATE TABLE order_operations
(
    order_id INT,
    user_id INT,
    operation_type VARCHAR(32),
    behavior_date DATE
)
DUPLICATE KEY(order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 1
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- 3. AGGREGATE KEY：预聚合指标表
--    相同聚合 Key 的数据会按照指标列的聚合函数合并，
--    例如 SUM 表示自动求和。
-- ============================================================

CREATE TABLE street_order_data
(
    behavior_date DATE,
    street_id INT,
    street_name VARCHAR(32),
    order_sum BIGINT SUM,
    cash_flow DECIMAL(18, 2) SUM
)
AGGREGATE KEY(behavior_date, street_id, street_name)
DISTRIBUTED BY HASH(street_id) BUCKETS 1
PROPERTIES
(
    "replication_num" = "1"
);

CREATE TABLE city_order_data
(
    behavior_date DATE,
    city_id INT,
    city_name VARCHAR(32),
    order_sum BIGINT SUM,
    cash_flow DECIMAL(18, 2) SUM
)
AGGREGATE KEY(behavior_date, city_id, city_name)
DISTRIBUTED BY HASH(city_id) BUCKETS 1
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- 测试用例 A：UNIQUE KEY
--
-- users.user_id 和 orders.order_id 是 Unique Key。
-- 多次插入相同 Key 后再查询。
-- 预期结果：
--   user_id = 1 应该显示最新城市：Shanghai
--   order_id = 1001 应该显示最新状态：paid
-- ============================================================

INSERT INTO users VALUES
(1, 'Alice', 'Beijing'),
(2, 'Bob', 'Shanghai');

INSERT INTO users VALUES
(1, 'Alice', 'Shanghai');

SELECT * FROM users ORDER BY user_id;

INSERT INTO orders VALUES
(1001, 1, 88.00, '2026-06-20', 'created'),
(1002, 2, 45.50, '2026-06-20', 'created');

INSERT INTO orders VALUES
(1001, 1, 88.00, '2026-06-20', 'paid');

SELECT * FROM orders ORDER BY order_id;

-- ============================================================
-- 测试用例 B：DUPLICATE KEY
--
-- user_behaviors 和 order_operations 是事件/流水明细表。
-- 插入重复的 user_id/order_id。
-- 预期结果：
--   重复 Key 不会被删除
--   每一条行为或操作记录都会被保留
-- ============================================================

INSERT INTO user_behaviors VALUES
(1, 'hot pot', 'shop_100', 'no', NULL, '2026-06-20'),
(1, 'hot pot', 'dish_200', 'yes', 1001, '2026-06-20'),
(1, 'milk tea', 'shop_300', 'no', NULL, '2026-06-20'),
(2, 'coffee', 'shop_400', 'yes', 1002, '2026-06-20');

SELECT * FROM user_behaviors ORDER BY user_id, behavior_date, query;

SELECT
    user_id,
    COUNT(*) AS behavior_count
FROM user_behaviors
GROUP BY user_id
ORDER BY user_id;

INSERT INTO order_operations VALUES
(1001, 1, 'created', '2026-06-20'),
(1001, 1, 'paid', '2026-06-20'),
(1001, 1, 'delivering', '2026-06-20'),
(1002, 2, 'created', '2026-06-20');

SELECT * FROM order_operations ORDER BY order_id, operation_type;

SELECT
    order_id,
    COUNT(*) AS operation_count
FROM order_operations
GROUP BY order_id
ORDER BY order_id;

-- ============================================================
-- 测试用例 C：AGGREGATE KEY
--
-- street_order_data 和 city_order_data 是预聚合指标表。
-- 插入相同聚合 Key 的多行数据。
-- 预期结果：
--   order_sum 和 cash_flow 会被自动求和
-- ============================================================

INSERT INTO street_order_data VALUES
('2026-06-20', 10, 'Wudaokou', 3, 120.50),
('2026-06-20', 10, 'Wudaokou', 2, 80.00),
('2026-06-20', 11, 'Zhongguancun', 1, 45.50);

SELECT
    behavior_date,
    street_id,
    street_name,
    order_sum,
    cash_flow,
    cash_flow / order_sum AS avg_cash_flow_per_order
FROM street_order_data
ORDER BY behavior_date, street_id;

INSERT INTO city_order_data VALUES
('2026-06-20', 1, 'Beijing', 5, 200.50),
('2026-06-20', 1, 'Beijing', 1, 45.50),
('2026-06-20', 2, 'Shanghai', 2, 99.00);

SELECT
    behavior_date,
    city_id,
    city_name,
    order_sum,
    cash_flow,
    cash_flow / order_sum AS avg_cash_flow_per_order
FROM city_order_data
ORDER BY behavior_date, city_id;



SHOW CREATE TABLE table_model_test.users;
SHOW CREATE TABLE table_model_test.user_behaviors;
SHOW CREATE TABLE table_model_test.city_order_data;


EXPLAIN
SELECT * FROM table_model_test.users ORDER BY user_id;


EXPLAIN
SELECT
    behavior_date,
    city_id,
    city_name,
    order_sum,
    cash_flow,
    cash_flow / order_sum AS avg_cash_flow_per_order
FROM table_model_test.city_order_data
ORDER BY behavior_date, city_id;


EXPLAIN
SELECT
    order_id,
    COUNT(*) AS operation_count
FROM table_model_test.order_operations
GROUP BY order_id
ORDER BY order_id;



EXPLAIN
INSERT INTO table_model_test.city_order_data VALUES
('2026-06-20', 1, 'Beijing', 5, 200.50),
('2026-06-20', 1, 'Beijing', 1, 45.50),
('2026-06-20', 2, 'Shanghai', 2, 99.00);




