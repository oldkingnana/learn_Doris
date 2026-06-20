CREATE DATABASE IF NOT EXISTS doris_learn;

USE doris_learn;

DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS users;

CREATE TABLE users
(
    user_id INT,
    user_name VARCHAR(32),
    city VARCHAR(32)
)
DUPLICATE KEY(user_id)
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
    order_date DATE
)
DUPLICATE KEY(order_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 1
PROPERTIES
(
    "replication_num" = "1"
);

INSERT INTO users VALUES
(1, 'Alice', 'Beijing'),
(2, 'Bob', 'Shanghai'),
(3, 'Cindy', 'Beijing'),
(4, 'David', 'Guangzhou');

INSERT INTO orders VALUES
(101, 1, 100.00, '2026-06-19'),
(102, 2, 200.00, '2026-06-19'),
(103, 1, 50.00, '2026-06-20'),
(104, 3, 80.00, '2026-06-20'),
(105, 4, 120.00, '2026-06-21');

SELECT * FROM users ORDER BY user_id;

SELECT * FROM orders ORDER BY order_id;

SELECT
    user_id,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM orders
GROUP BY user_id
ORDER BY user_id;

SELECT
    u.city,
    COUNT(*) AS order_count,
    SUM(o.amount) AS total_amount
FROM orders AS o
JOIN users AS u
    ON o.user_id = u.user_id
GROUP BY u.city
ORDER BY total_amount DESC;
