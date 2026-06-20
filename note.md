### 1 什么是`Doris`

* 明确一下概念,`Doris`也是`SQL`型数据库
* 属于`OLAP`(Online Analytical Processing, 在线分析处理)型数据库
* 相对的,`MySQL`是`OLTP`(On-Line Transaction Processing, 联机事务处理)型数据库
* `Doris`采用列式存储
* `Doris`采用`MPP`(Massively Parallel Processing, 大规模并行处理)架构
* `MPP`从某种角度上说其实类似于分布式,但并不仅仅是传统存储分布式,而是连查询操作也被拆分成多个任务到多台服务器,也就是说多台服务器可以并行查询,这在效率上是极大的提高,代价就是比较贵


* 简单来说,`Doris`旨在解决一下几个问题:
    1. `MySQL`在综合能力比较强,但面对大规模分析型查询时不合适
    2. 传统`OLTP`数据库很难做统计的问题,需要快速获取统计数据
    3. 无需繁杂链路,导入数据到`Doris`得能即查即用
    4. 高吞吐导入效率得高

* 或者说`MySQL`更加综合,`Doris`更加专一

* 更深入的说:
    1. `MySQL`的`MVCC`因为考虑回滚,事务隔离等问题,成本相对更高,而`Doris`对数据版本机制有一些独有的优化
    2. 因为`InnoDB`按照行存储,在`OLAP`下会导致磁盘会读到很多无用列,页访问压力更大,效率更低,而`Doris`用列存储,对于行极多的场景,读取时减少无关列`IO`
    3. `MySQL`使用一些中间件才能实现`MPP`, `Doris`天然支持`MPP`
    4. `MySQL`做大规模聚合的时候会构建大量临时表,效率太低,`Doris`会通过执行计划少构建无意义中间结果

* 另外我们对一个名词作解释,我在看相关视频和博客的时候经常有提到这个词,即`shuffle join`
* 前面我们提到过`Doris`天然支持`MPP`,我们暂时把每一台服务器按照`BE1/BE2/..`取名(`BE`本质是一个服务)
* 如果在单机`MySQL`中,我们对两个表(`A/B`)做`join`查询,最坏也是查完`A`得到中间数据之后跑到另一个磁盘的表`B`接着查
* 如果在分布式中,或许是搞一个哈希表或者b树之类的玩意描述多个机器存了哪些范围的数据,然后在一个服务器上部署一个专门用于路由的服务
* 但是`Doris`是这样实现的,查询操作会被分为多个查询给到不同服务器,比方说对`BE1`的表`A`做查询得到中间数据,然后对`BE2`的表`B`做查询得到中间数据,因为`join`需要拼接/合并这两个临时数据,所以`BE1`和`BE2`会让`join key`经过同一个哈希算法,目的是知道这个数据应该交给那个服务器合并,比方说定位到了`BE3`做合并处理,那么`BE1`和`BE2`都会把得到的临时数据发给`BE3`
* 其实某种意义上和单机`MySQL`中的情况其实是差不多的,本质上都是为了让两边能够匹配的数据相遇
* 好处在于这种形式能把实际`join`操作交给很多台机器并行执行,效率更高,代价就是需要网络环境非常好,如果`join key`不够均匀,那么还会导致数据倾斜,可能会往单机`join`退化

### 2 实际跑一下`Doris`

* `Doris`是这样设计的
* 首先`Doris`分为两类进程,`Frontend`(`FE`)和`Backend`(`BE`)
* 关于两个进程的职责,我们可以简单理解为`FE`负责宏观调控/下发任务/数据分布描述/机器管理,`BE`则负责执行任务和储存数据,多个`BE`就实现了并行执行任务
* 所以`Doris`的经典部署方式是存算一体架构,`BE`既负责存储又负责计算

* 所以安装的时候你会发现我们至少需要启动两个进程才能运行,安装这部分按照官方的参考文档来就行

### 3 表模型

* `Doris`中的`Key`和`MySQL`中的索引/约束不是完全一回事
* `Doris`的`Duplicate Key`/`Unique Key`/`Aggregate Key`更像是在选择一种表模型,也就是告诉`Doris`:当多行数据拥有相同`Key`时应该如何处理
    1. `Duplicate Key`: 明细,插入新行不会因为`key`相同而顶掉旧行,允许新行和旧行同时存在,适合必须保留所有原始数据记录的情况
    2. `Unique Key`: 主键,插入新行会顶掉相同`key`的旧数据,适合需要唯一主键约束且数据会被持续更新的情况
    3. `Aggregate Key`: 聚合,插入新行会使非`key`部分合并(比方说取和),维度固定的报表类查询

#### 3.4 `Distributed By`

* 你可能会在`SQL`语句中看到`Distributed By`,这是一种数据分布策略
* 它决定一张表的数据按照哪个字段做`Hash`分桶
* 比方说`DISTRIBUTED BY HASH(user_id) BUCKETS 8`,意思是按照`user_id`做哈希,把数据分成`8`个桶
* 多`BE`配合多`Bucket`时,数据可以分散到多个节点,查询时也能并行扫描
* 这就可以让数据尽量均匀分布,为并行查询做准备

#### 3.5 `Properties`

* `Properties`是表级配置,用于描述这张表的底层行为
* 比方说本地单`BE`测试时一般:

```sql
PROPERTIES
(
    "replication_num" = "1"
);
```

* 这是因为本地只有一个`BE`,只能保存一份副本
* `SHOW CREATE TABLE`时可以看到`Doris`会把很多默认配置补全出来,常见属性包括副本分布/存储格式/是否启用`Merge-on-Write`/是否启用自动`Compaction`等

### 4 `Stream Load`

* `Stream Load`是`Doris`常见的数据导入方式之一,通过`HTTP`把文件批量导入`Doris`,而不是一行一行执行`INSERT`
* 这更符合`OLAP`场景,因为分析系统通常需要高吞吐导入日志/行为/订单等数据
* 我们可以使用`curl`向`Doris`发送一个`HTTP`包用于导入本地数据,具体字段可参考官方文档
* 导入失败时,返回结果中的`ErrorURL`可以查看本次导入的数据错误明细

### 5 `EXPLAIN`与查询优化器

* `EXPLAIN`用于查看一条`SQL`的执行计划,告诉我们`Doris`准备如何执行这条语句
* `Doris`有基于成本的查询优化器,也就是`CBO`(`Cost-Based Optimizer`),是`FE`功能的一部分
* `CBO`会根据表大小/列统计信息/过滤条件/连接方式/数据交换成本等因素,选择它认为成本较低的执行计划

* 常见执行节点可以先这样理解:
    1. `VOlapScanNode`:扫描`Doris`的`OLAP`表
    2. `VAGGREGATE`:做聚合,比如`GROUP BY`/`COUNT`/`SUM`
    3. `VSORT`:做排序,对应`ORDER BY`
    4. `EXCHANGE`:执行片段之间交换数据
    5. `RESULT SINK`:把结果返回给客户端

* 案例

```SQL
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

-- 插入一堆行

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
```

![[Pasted image 20260620084944.png]]

* 即这条`SQL`语句被划分为两个计划,一个叫做`PLAN FRAGMENT 0`,另一个叫做`PLAN FRAGMENT 1`
* 整个计划其实是到着走的,或者说划分的时候是从宏观到微观的
    1. 首先扫描了`OLAP`表,然后获取到了需要的列
    2. 然后做排序
    3. 做数据交换,将排序后的数据汇总交给一台机器用于发送

### 6 Join与MPP执行

* `Join`的本质是把两张表中能匹配的数据拼在一起
* `Hash Join`的基本思路是:用较小的数据流按照`Join Key`构建哈希表,再用另一侧数据流的`Join Key`去哈希表里查找匹配行
* 在分布式场景下,`Doris`需要决定两侧数据如何相遇

#### 6.1 Broadcast Join

* `Broadcast Join`表示广播连接,适合小表`Join`大表
* 基本做法是把小表数据广播到执行大表扫描的多个`BE`上,每个`BE`在本地完成`Hash Join`
* 好处是大表不用大量移动,代价是小表会被复制多份,占用网络和内存

#### 6.2 Shuffle Join

* `Shuffle Join`表示洗牌连接/重分布连接
* 它会按照`Join Key`对两侧中间数据重新做`Hash`分发
* 目标是让相同`Join Key`的数据到同一个`BE`上完成`Join`
* 如果`Join Key`分布不均匀,可能导致数据倾斜,某些`BE`压力特别大
* 所以当两侧数据都比较大时,通过`Shuffle Join`让能匹配的数据相遇

#### 6.3 两阶段聚合

* 在`MPP`执行中,聚合通常会拆成两阶段
* 第一阶段是局部聚合,各个`BE`先在本地把相同`group key`的数据合并
* 然后通过`Hash Exchange`按照`group key`重新分发中间结果
* 第二阶段是最终聚合,把来自不同`BE`的同一个`group key`的局部结果合并成全局结果

* 案例
```SQL
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

-- 插入一堆数据

EXPLAIN
SELECT
    p.user_level,
    COUNT(*) AS behavior_count
FROM user_behavior_detail AS b
JOIN user_profile AS p
    ON b.user_id = p.user_id
GROUP BY p.user_level
ORDER BY behavior_count DESC;
```

![[Pasted image 20260620090013.png]]
![[Pasted image 20260620090033.png]]
![[Pasted image 20260620090100.png]]

![[Pasted image 20260620063233.png]]

#### 6.4 排序与结果返回

* 如果查询中有`ORDER BY`,执行计划中通常会出现`VSORT`
* 多`BE`场景下,每个执行节点可能先对自己负责的数据做局部排序
* 上层的`Merging Exchange`再把多个有序数据流合并成全局有序结果
* 最终通过`MySQL`协议返回给客户端

