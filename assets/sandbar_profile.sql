-- =================================================================
-- 洲滩自动识别与整理系统 - 数据库建表脚本
-- 数据库类型: PostgreSQL + PostGIS
-- 编码格式: UTF8
-- =================================================================

-- 1. 启用 PostGIS 空间扩展插件（如果尚未启用）
CREATE EXTENSION IF NOT EXISTS postgis;

-- =================================================================
-- 2. 创建洲滩基础信息表 (sandbar_profile)
-- 说明: 存储每个洲滩“一生不变”的静态身份信息，以基础ID为主键
-- =================================================================
CREATE TABLE IF NOT EXISTS sandbar_profile (
    -- 主键：洲滩的基础ID (19位)，例如: YZ05426249626129261
    base_id VARCHAR(19) PRIMARY KEY,
    
    -- 流域段代码 (3位)，例如: YZ0 (中游)
    river_section VARCHAR(3) NOT NULL,
    
    -- 行政区代码 (6位)，例如: 542624 (米林县)
    admin_code VARCHAR(6) NOT NULL,
    
    -- 地理位置码 (10位)，经度5位+纬度5位，例如: 9626129261
    location_code VARCHAR(10) NOT NULL,
    
    -- 空间字段：洲滩的质心坐标点，使用 WGS84 坐标系 (SRID: 4326)
    centroid GEOMETRY(Point, 4326) NOT NULL,
    
    -- 首次被系统识别到的日期
    initial_discovery_date DATE NOT NULL,
    
    -- 记录创建时间，默认为当前时间
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 为行政区代码创建索引，加速按区域查询
CREATE INDEX idx_profile_admin_code ON sandbar_profile(admin_code);


-- =================================================================
-- 3. 创建洲滩动态历史表 (sandbar_history)
-- 说明: 记录洲滩在每一个时间点的“快照”，是系统的核心数据表
-- =================================================================
CREATE TABLE IF NOT EXISTS sandbar_history (
    -- 主键：自增的唯一标识符
    id BIGSERIAL PRIMARY KEY,
    
    -- 外键：关联到基础信息表的基础ID
    base_id VARCHAR(19) NOT NULL,
    
    -- 完整的数字身份证 (22位)，例如: YZ05426249626129261_DS
    -- 注：实际开发中可设为生成列，此处为兼容性采用普通字段
    full_id VARCHAR(22) NOT NULL,
    
    -- 观测日期（影像获取日期）
    observation_date DATE NOT NULL,
    
    -- 水文期属性码 (1位): D(枯水期), N(平水期), F(丰水期)
    hydro_period CHAR(1) NOT NULL CHECK (hydro_period IN ('D', 'N', 'F')),
    
    -- 动态形态码 (1位): S(稳定), Y(游荡), X(新生/消亡)
    morphology CHAR(1) NOT NULL CHECK (morphology IN ('S', 'Y', 'X')),
    
    -- 空间字段：洲滩在该时间点的实际多边形轮廓，使用 WGS84 坐标系
    geometry GEOMETRY(Polygon, 4326) NOT NULL,
    
    -- 洲滩面积（平方米）
    area DOUBLE PRECISION NOT NULL,
    
    -- 洲滩周长（米）
    perimeter DOUBLE PRECISION NOT NULL,
    
    -- 记录创建时间
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    -- 设置外键约束，确保基础ID必须存在于基础信息表中
    CONSTRAINT fk_base_id FOREIGN KEY (base_id) 
        REFERENCES sandbar_profile(base_id) ON DELETE CASCADE
);

-- 为观测日期和基础ID创建联合索引，极速查询单个洲滩的演变历史
CREATE INDEX idx_history_base_date ON sandbar_history(base_id, observation_date);

-- 为空间字段创建 GIST 索引，加速空间查询（如：查找某区域内的洲滩）
CREATE INDEX idx_history_geometry ON sandbar_history USING GIST (geometry);


-- =================================================================
-- 4. 创建自动更新形心的触发器函数 (可选的高级功能)
-- 说明: 当向历史表插入新数据时，自动计算形心并更新到基础表
-- =================================================================
CREATE OR REPLACE FUNCTION update_sandbar_centroid()
RETURNS TRIGGER AS $$
BEGIN
    -- 如果基础表中不存在该ID，则插入（形心使用 ST_Centroid 计算）
    -- 如果存在，则仅更新形心坐标
    INSERT INTO sandbar_profile (base_id, river_section, admin_code, location_code, centroid, initial_discovery_date)
    VALUES (
        NEW.base_id,
        -- 从 full_id 中截取前3位作为 river_section (假设命名规则严格)
        LEFT(NEW.full_id, 3), 
        -- 从 full_id 中截取第4-9位作为 admin_code
        SUBSTRING(NEW.full_id FROM 4 FOR 6), 
        -- 从 full_id 中截取第10-19位作为 location_code
        SUBSTRING(NEW.full_id FROM 10 FOR 10), 
        -- 核心：计算多边形的几何中心。若中心点在多边形外，则取表面上的点
        COALESCE(
            CASE WHEN ST_Within(ST_Centroid(NEW.geometry), NEW.geometry) 
                 THEN ST_Centroid(NEW.geometry) 
                 ELSE ST_PointOnSurface(NEW.geometry) 
            END, 
            ST_Centroid(NEW.geometry)
        ),
        NEW.observation_date
    )
    ON CONFLICT (base_id) 
    DO UPDATE SET 
        centroid = EXCLUDED.centroid;
        
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 将触发器绑定到历史表上
CREATE TRIGGER trigger_update_centroid
AFTER INSERT ON sandbar_history
FOR EACH ROW
EXECUTE FUNCTION update_sandbar_centroid();