/* =====================================================================
   PROJECT : Analisis Penjualan E-Commerce Indonesia 2025
   PERAN   : Data Analyst
   DBMS    : PostgreSQL (jalankan di pgAdmin / DBeaver / psql)
   ---------------------------------------------------------------------
   PERTANYAAN BISNIS
   1. Bagaimana performa penjualan secara keseluruhan (KPI)?
   2. Bagaimana tren revenue bulanan dan pertumbuhannya?
   3. Kategori & produk apa yang paling menyumbang revenue?
   4. Kota mana yang paling potensial?
   5. Siapa pelanggan terbaik & bagaimana segmentasinya (RFM)?
   6. Berapa tingkat repeat purchase?
   7. Metode pembayaran mana yang paling sering cancel/return?
   ===================================================================== */


/* =====================================================================
   BAGIAN 1 : DATABASE SCHEMA
   ===================================================================== */
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
    customer_id  SERIAL PRIMARY KEY,
    name         VARCHAR(100) NOT NULL,
    city         VARCHAR(50)  NOT NULL,
    signup_date  DATE         NOT NULL
);

CREATE TABLE products (
    product_id   SERIAL PRIMARY KEY,
    product_name VARCHAR(100) NOT NULL,
    category     VARCHAR(50)  NOT NULL,
    price        NUMERIC(12,2) NOT NULL CHECK (price > 0)
);

CREATE TABLE orders (
    order_id       SERIAL PRIMARY KEY,
    customer_id    INT NOT NULL REFERENCES customers(customer_id),
    order_date     DATE NOT NULL,
    status         VARCHAR(20) NOT NULL
                   CHECK (status IN ('completed','cancelled','returned')),
    payment_method VARCHAR(30) NOT NULL
);

CREATE TABLE order_items (
    order_item_id SERIAL PRIMARY KEY,
    order_id      INT NOT NULL REFERENCES orders(order_id),
    product_id    INT NOT NULL REFERENCES products(product_id),
    quantity      INT NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(12,2) NOT NULL
);

CREATE INDEX idx_orders_date     ON orders(order_date);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_items_order     ON order_items(order_id);


/* =====================================================================
   BAGIAN 2 : DATA DUMMY (di-generate otomatis)
   ===================================================================== */
SELECT setseed(0.42);  -- agar hasil bisa direproduksi

INSERT INTO products (product_name, category, price) VALUES
 ('Smartphone X1',        'Elektronik',   3500000),
 ('Earbuds Pro',          'Elektronik',    450000),
 ('Smartwatch Fit',       'Elektronik',   1200000),
 ('Kaos Polos Premium',   'Fashion',        85000),
 ('Jaket Hoodie',         'Fashion',       250000),
 ('Sepatu Sneakers',      'Fashion',       550000),
 ('Rice Cooker 1.8L',     'Rumah Tangga',  350000),
 ('Blender Multifungsi',  'Rumah Tangga',  275000),
 ('Set Panci Anti Lengket','Rumah Tangga', 420000),
 ('Serum Wajah',          'Kecantikan',    120000),
 ('Sunscreen SPF 50',     'Kecantikan',     75000),
 ('Parfum Eau de Toilette','Kecantikan',   300000);

INSERT INTO customers (name, city, signup_date)
SELECT 'Customer ' || g,
       (ARRAY['Jakarta','Bandung','Surabaya','Medan',
              'Yogyakarta','Makassar','Denpasar','Semarang'])[1 + floor(random()*8)::int],
       DATE '2024-01-01' + floor(random()*365)::int
FROM generate_series(1, 200) g;

INSERT INTO orders (customer_id, order_date, status, payment_method)
SELECT 1 + floor(random()*200)::int,
       DATE '2025-01-01' + floor(random()*365)::int,
       (ARRAY['completed','completed','completed','completed',
              'cancelled','returned'])[1 + floor(random()*6)::int],
       (ARRAY['e-wallet','bank_transfer','credit_card','cod'])[1 + floor(random()*4)::int]
FROM generate_series(1, 1500);

-- setiap order berisi 1-3 produk berbeda
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT o.order_id, p.product_id, 1 + floor(random()*3)::int, p.price
FROM orders o
CROSS JOIN LATERAL (
    SELECT product_id, price
    FROM products
    ORDER BY random()
    LIMIT 1 + (o.order_id % 3)
) p;


/* =====================================================================
   BAGIAN 3 : DATA QUALITY CHECK
   ===================================================================== */
-- 3.1 Jumlah baris tiap tabel
SELECT 'customers' AS tabel, COUNT(*) AS jumlah FROM customers
UNION ALL SELECT 'products',    COUNT(*) FROM products
UNION ALL SELECT 'orders',      COUNT(*) FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items;

-- 3.2 Order tanpa item (seharusnya 0)
SELECT COUNT(*) AS order_tanpa_item
FROM orders o
LEFT JOIN order_items oi ON oi.order_id = o.order_id
WHERE oi.order_id IS NULL;

-- 3.3 Duplikat nama produk (seharusnya kosong)
SELECT product_name, COUNT(*)
FROM products
GROUP BY product_name
HAVING COUNT(*) > 1;


/* =====================================================================
   BAGIAN 4 : ANALISIS
   Definisi: Revenue = quantity * unit_price, hanya untuk status 'completed'
   ===================================================================== */

-- ---------------------------------------------------------------
-- Q1. KPI UTAMA
-- ---------------------------------------------------------------
SELECT
    COUNT(DISTINCT o.order_id)                              AS total_order,
    COUNT(DISTINCT o.customer_id)                           AS total_customer_aktif,
    SUM(oi.quantity)                                        AS total_unit_terjual,
    SUM(oi.quantity * oi.unit_price)                        AS total_revenue,
    ROUND(SUM(oi.quantity * oi.unit_price)
          / COUNT(DISTINCT o.order_id), 0)                  AS avg_order_value
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'completed';


-- ---------------------------------------------------------------
-- Q2. TREN REVENUE BULANAN + MoM GROWTH (window function LAG)
-- ---------------------------------------------------------------
WITH monthly AS (
    SELECT DATE_TRUNC('month', o.order_date)::date AS bulan,
           SUM(oi.quantity * oi.unit_price)        AS revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT bulan,
       revenue,
       LAG(revenue) OVER (ORDER BY bulan) AS revenue_bulan_lalu,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY bulan))
             / NULLIF(LAG(revenue) OVER (ORDER BY bulan), 0), 2) AS mom_growth_pct,
       SUM(revenue) OVER (ORDER BY bulan)  AS revenue_kumulatif
FROM monthly
ORDER BY bulan;


-- ---------------------------------------------------------------
-- Q3. REVENUE & KONTRIBUSI PER KATEGORI
-- ---------------------------------------------------------------
SELECT p.category,
       SUM(oi.quantity)                          AS unit_terjual,
       SUM(oi.quantity * oi.unit_price)          AS revenue,
       ROUND(100.0 * SUM(oi.quantity * oi.unit_price)
             / SUM(SUM(oi.quantity * oi.unit_price)) OVER (), 2) AS kontribusi_pct
FROM order_items oi
JOIN orders   o ON o.order_id   = oi.order_id
JOIN products p ON p.product_id = oi.product_id
WHERE o.status = 'completed'
GROUP BY p.category
ORDER BY revenue DESC;


-- ---------------------------------------------------------------
-- Q4. PRODUK TERLARIS PER KATEGORI (ROW_NUMBER + PARTITION)
-- ---------------------------------------------------------------
WITH product_rev AS (
    SELECT p.category,
           p.product_name,
           SUM(oi.quantity * oi.unit_price) AS revenue
    FROM order_items oi
    JOIN orders   o ON o.order_id   = oi.order_id
    JOIN products p ON p.product_id = oi.product_id
    WHERE o.status = 'completed'
    GROUP BY p.category, p.product_name
)
SELECT category, product_name, revenue, peringkat
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY category ORDER BY revenue DESC) AS peringkat
    FROM product_rev
) t
WHERE peringkat <= 2
ORDER BY category, peringkat;


-- ---------------------------------------------------------------
-- Q5. PERFORMA PER KOTA
-- ---------------------------------------------------------------
SELECT c.city,
       COUNT(DISTINCT o.order_id)                 AS total_order,
       COUNT(DISTINCT c.customer_id)              AS jumlah_customer,
       SUM(oi.quantity * oi.unit_price)           AS revenue,
       ROUND(SUM(oi.quantity * oi.unit_price)
             / COUNT(DISTINCT c.customer_id), 0)  AS revenue_per_customer
FROM customers c
JOIN orders      o  ON o.customer_id = c.customer_id
JOIN order_items oi ON oi.order_id   = o.order_id
WHERE o.status = 'completed'
GROUP BY c.city
ORDER BY revenue DESC;


-- ---------------------------------------------------------------
-- Q6. TOP 10 CUSTOMER (RANK)
-- ---------------------------------------------------------------
SELECT RANK() OVER (ORDER BY SUM(oi.quantity * oi.unit_price) DESC) AS peringkat,
       c.customer_id,
       c.name,
       c.city,
       COUNT(DISTINCT o.order_id)          AS jumlah_order,
       SUM(oi.quantity * oi.unit_price)    AS total_belanja
FROM customers c
JOIN orders      o  ON o.customer_id = c.customer_id
JOIN order_items oi ON oi.order_id   = o.order_id
WHERE o.status = 'completed'
GROUP BY c.customer_id, c.name, c.city
ORDER BY peringkat
LIMIT 10;


-- ---------------------------------------------------------------
-- Q7. SEGMENTASI RFM (Recency, Frequency, Monetary) dengan NTILE
-- ---------------------------------------------------------------
WITH rfm_base AS (
    SELECT o.customer_id,
           (DATE '2025-12-31' - MAX(o.order_date))  AS recency_days,
           COUNT(DISTINCT o.order_id)               AS frequency,
           SUM(oi.quantity * oi.unit_price)         AS monetary
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status = 'completed'
    GROUP BY o.customer_id
),
rfm_score AS (
    SELECT *,
           NTILE(4) OVER (ORDER BY recency_days DESC) AS r_score, -- makin baru makin tinggi
           NTILE(4) OVER (ORDER BY frequency)         AS f_score,
           NTILE(4) OVER (ORDER BY monetary)          AS m_score
    FROM rfm_base
),
rfm_segment AS (
    SELECT *,
           CASE
             WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3 THEN 'Champions'
             WHEN f_score >= 3 AND m_score >= 3                  THEN 'Loyal'
             WHEN r_score >= 3                                   THEN 'Potential / Baru'
             WHEN r_score <= 2 AND f_score >= 3                  THEN 'At Risk'
             ELSE 'Hibernating'
           END AS segmen
    FROM rfm_score
)
SELECT segmen,
       COUNT(*)                     AS jumlah_customer,
       ROUND(AVG(recency_days), 0)  AS avg_recency_hari,
       ROUND(AVG(frequency), 1)     AS avg_frequency,
       ROUND(AVG(monetary), 0)      AS avg_monetary
FROM rfm_segment
GROUP BY segmen
ORDER BY avg_monetary DESC;


-- ---------------------------------------------------------------
-- Q8. REPEAT CUSTOMER RATE
-- ---------------------------------------------------------------
WITH cust_orders AS (
    SELECT customer_id, COUNT(*) AS jml_order
    FROM orders
    WHERE status = 'completed'
    GROUP BY customer_id
)
SELECT COUNT(*)                                             AS total_customer,
       COUNT(*) FILTER (WHERE jml_order > 1)                AS repeat_customer,
       ROUND(100.0 * COUNT(*) FILTER (WHERE jml_order > 1)
             / COUNT(*), 2)                                 AS repeat_rate_pct
FROM cust_orders;


-- ---------------------------------------------------------------
-- Q9. CANCEL & RETURN RATE PER METODE PEMBAYARAN
-- ---------------------------------------------------------------
SELECT payment_method,
       COUNT(*)                                                       AS total_order,
       COUNT(*) FILTER (WHERE status = 'cancelled')                   AS cancelled,
       COUNT(*) FILTER (WHERE status = 'returned')                    AS returned,
       ROUND(100.0 * COUNT(*) FILTER (WHERE status <> 'completed')
             / COUNT(*), 2)                                           AS gagal_pct
FROM orders
GROUP BY payment_method
ORDER BY gagal_pct DESC;


-- ---------------------------------------------------------------
-- Q10. POLA HARI DALAM SEMINGGU
-- ---------------------------------------------------------------
SELECT TO_CHAR(o.order_date, 'Day')            AS hari,
       EXTRACT(ISODOW FROM o.order_date)       AS urutan,
       COUNT(DISTINCT o.order_id)              AS total_order,
       SUM(oi.quantity * oi.unit_price)        AS revenue
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'completed'
GROUP BY 1, 2
ORDER BY urutan;


-- ---------------------------------------------------------------
-- Q11. PRODUK YANG SERING DIBELI BERSAMA (Market Basket sederhana)
-- ---------------------------------------------------------------
SELECT p1.product_name AS produk_a,
       p2.product_name AS produk_b,
       COUNT(*)        AS frekuensi_bersama
FROM order_items a
JOIN order_items b ON a.order_id = b.order_id AND a.product_id < b.product_id
JOIN products p1   ON p1.product_id = a.product_id
JOIN products p2   ON p2.product_id = b.product_id
JOIN orders o      ON o.order_id = a.order_id AND o.status = 'completed'
GROUP BY p1.product_name, p2.product_name
ORDER BY frekuensi_bersama DESC
LIMIT 10;


/* =====================================================================
   BAGIAN 5 : VIEW UNTUK DASHBOARD (Tableau / Power BI / Looker Studio)
   ===================================================================== */
CREATE OR REPLACE VIEW vw_sales_detail AS
SELECT o.order_id,
       o.order_date,
       o.status,
       o.payment_method,
       c.customer_id,
       c.city,
       p.product_name,
       p.category,
       oi.quantity,
       oi.unit_price,
       oi.quantity * oi.unit_price AS line_revenue
FROM orders o
JOIN customers   c  ON c.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id   = o.order_id
JOIN products    p  ON p.product_id  = oi.product_id;

/* =====================================================================
   BAGIAN 6 : TEMPLATE KESIMPULAN & REKOMENDASI (isi setelah query dijalankan)
   ---------------------------------------------------------------------
   INSIGHT
   - Revenue total ... dengan AOV ...
   - Bulan terbaik ... ; bulan terendah ...
   - Kategori ... menyumbang ...% revenue
   - Kota ... memiliki revenue per customer tertinggi
   - Repeat rate ...% -> ruang perbaikan retensi
   - Metode pembayaran ... memiliki gagal_pct tertinggi

   REKOMENDASI
   1. Fokuskan promo pada kategori/produk berkontribusi tinggi
   2. Kampanye win-back untuk segmen "At Risk" & "Hibernating"
   3. Bundling produk dari hasil market basket (Q11)
   4. Investigasi penyebab cancel pada metode pembayaran bermasalah
   ===================================================================== */
