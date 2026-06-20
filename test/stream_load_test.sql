CREATE DATABASE IF NOT EXISTS stream_load_test;

USE stream_load_test;

DROP TABLE IF EXISTS user_behavior_stream;

-- ============================================================
-- Stream Load 测试表
--
-- Stream Load 是 Doris 常用的数据导入方式之一。
-- 它不是一行一行 INSERT，而是通过 HTTP 把一个文件批量导入 Doris。
--
-- 这里使用 DUPLICATE KEY，因为用户行为是典型事件明细：
-- 同一个用户可以多次搜索、点击、下单，每一条行为都应该被保留。
-- ============================================================

CREATE TABLE user_behavior_stream
(
    behavior_id BIGINT,
    user_id INT,
    event_type VARCHAR(32),
    page_name VARCHAR(64),
    city VARCHAR(32),
    event_time DATETIME,
    order_amount DECIMAL(10, 2)
)
DUPLICATE KEY(behavior_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 1
PROPERTIES
(
    "replication_num" = "1"
);

-- ============================================================
-- 手动导入命令
--
-- 注意：
-- 1. 这段不是 SQL，不要在 DBUI 里执行。
-- 2. 请在终端里执行。
-- 3. CSV 第一行是表头，所以加 skip_lines:1 跳过表头。
-- 4. columns 用来声明 CSV 每一列对应 Doris 表里的哪一列。
--
-- 如果当前路径是 /home/oldking/learn_Doris，可以执行：
--
-- curl --location-trusted \
--   -u root: \
--   -H "label:user_behavior_stream_20260620_01" \
--   -H "column_separator:," \
--   -H "skip_lines:1" \
--   -H "columns:behavior_id,user_id,event_type,page_name,city,event_time,order_amount" \
--   -T test/user_behavior.csv \
--   http://127.0.0.1:8040/api/stream_load_test/user_behavior_stream/_stream_load
--
-- 其中：
--   8040 是 BE 的 HTTP 端口
--   stream_load_test 是数据库名
--   user_behavior_stream 是表名
--   label 是本次导入任务的名字，同一个 label 不要重复使用
-- ============================================================

-- 导入后查看数据
USE stream_load_test;
SELECT * FROM user_behavior_stream ORDER BY behavior_id;

-- 按事件类型统计行为次数
SELECT
    event_type,
    COUNT(*) AS event_count
FROM user_behavior_stream
GROUP BY event_type
ORDER BY event_count DESC;

-- 按城市统计下单金额
SELECT
    city,
    COUNT(*) AS behavior_count,
    SUM(order_amount) AS total_order_amount
FROM user_behavior_stream
GROUP BY city
ORDER BY total_order_amount DESC;

-- 查看执行计划：扫描、聚合、排序
EXPLAIN
SELECT
    city,
    COUNT(*) AS behavior_count,
    SUM(order_amount) AS total_order_amount
FROM user_behavior_stream
GROUP BY city
ORDER BY total_order_amount DESC;
