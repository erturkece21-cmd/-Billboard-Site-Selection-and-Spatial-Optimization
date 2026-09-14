-- 1. VERİ HAZIRLIĞI VE KOORDİNAT DÖNÜŞÜMÜ[cite: 8]
ALTER TABLE yapi ADD COLUMN geom_metric geometry(MultiPolygon, 5254);
UPDATE yapi SET geom_metric = ST_Multi(ST_MakeValid(ST_SetSRID(poly, 5254)));
CREATE INDEX ON yapi USING GIST (geom_metric);
ANALYZE yapi;

CREATE TABLE kadikoy_sinir AS
SELECT 1 AS tid, ST_Union(geom_metric) AS geom_metric
FROM aktar_geomahalle;
CREATE INDEX ON kadikoy_sinir USING GIST (geom_metric);

CREATE TABLE osm_yol AS
SELECT y.ogc_fid, y.osm_id, y.name AS yol_adi, y.fclass,
       y.maxspeed, y.oneway, y.geom_metric
FROM osm_yol_ham y, kadikoy_sinir k
WHERE ST_Intersects(y.geom_metric, k.geom_metric);
ALTER TABLE osm_yol ADD CONSTRAINT pk_osm_yol PRIMARY KEY (ogc_fid);
CREATE INDEX ON osm_yol USING GIST (geom_metric);
ANALYZE osm_yol;

-- 2. DASİMETRİK NÜFUS DAĞITIMI[cite: 8]
ALTER TABLE geokapi ADD COLUMN mahalle_id INT;
ALTER TABLE geokapi ADD COLUMN nufus_yuku NUMERIC;

UPDATE geokapi k SET mahalle_id = m.tid
FROM aktar_geomahalle m
WHERE ST_Intersects(k.geom_metric, m.geom_metric);

WITH kapi_sayilari AS (
    SELECT mahalle_id, COUNT(*) AS toplam_kapi
    FROM geokapi WHERE mahalle_id IS NOT NULL
    GROUP BY mahalle_id
)
UPDATE geokapi k
SET nufus_yuku = (m.nufus::NUMERIC / ks.toplam_kapi)
FROM aktar_geomahalle m
JOIN kapi_sayilari ks ON m.tid = ks.mahalle_id
WHERE k.mahalle_id = m.tid;

-- 3. ÇÖZÜM UZAYI VE ADAY NOKTALAR[cite: 8]
CREATE TABLE aday_noktalar AS
WITH parcali_yollar AS (
    SELECT (ST_DumpPoints(ST_Segmentize(geom_metric, 10))).geom AS geom_metric
    FROM osm_yol
)
SELECT row_number() OVER () AS aday_id, geom_metric
FROM parcali_yollar;
CREATE INDEX idx_aday_noktalar_geom ON aday_noktalar USING GIST (geom_metric);

ALTER TABLE aday_noktalar ADD COLUMN IF NOT EXISTS trafik_skoru NUMERIC DEFAULT 1.0;

-- 4. OPTİMİZASYON ALGORİTMASI (AÇGÖZLÜ KÜME KAPLAMA)[cite: 8]
CREATE OR REPLACE FUNCTION acgozlu_trafikli_secim(
    hedef_pano INT, min_mesafe FLOAT, etki_yaricapi FLOAT)
RETURNS TABLE (sira INT, secilen_aday_id INT, yaya_nufus NUMERIC,
               trafik_carpani NUMERIC, toplam_skor NUMERIC) AS $$
DECLARE
    mevcut_aday RECORD;
    i INT := 1;
BEGIN
    DROP TABLE IF EXISTS temp_kapi_durum;
    CREATE TEMP TABLE temp_kapi_durum AS
    SELECT geom_metric, nufus_yuku, FALSE AS kapsandi_mi FROM geokapi;
    CREATE INDEX ON temp_kapi_durum USING GIST (geom_metric);
 
    DROP TABLE IF EXISTS temp_secilenler;
    CREATE TEMP TABLE temp_secilenler (aday_id INT, geom_metric geometry);
    CREATE INDEX ON temp_secilenler USING GIST (geom_metric);
 
    WHILE i <= hedef_pano LOOP
        SELECT a.aday_id, a.geom_metric, a.trafik_skoru,
               COALESCE(SUM(k.nufus_yuku), 0) AS net_yaya,
               (COALESCE(SUM(k.nufus_yuku), 0) * a.trafik_skoru) AS max_skor
        INTO mevcut_aday
        FROM aday_noktalar a
        JOIN temp_kapi_durum k
          ON ST_DWithin(a.geom_metric, k.geom_metric, etki_yaricapi)
        WHERE k.kapsandi_mi = FALSE
          AND NOT EXISTS (
              SELECT 1 FROM temp_secilenler s
              WHERE ST_DWithin(a.geom_metric, s.geom_metric, min_mesafe))
        GROUP BY a.aday_id, a.geom_metric, a.trafik_skoru
        ORDER BY max_skor DESC, a.aday_id
        LIMIT 1;
 
        IF mevcut_aday.aday_id IS NULL THEN EXIT; END IF;
 
        INSERT INTO temp_secilenler VALUES (mevcut_aday.aday_id, mevcut_aday.geom_metric);
 
        sira := i; secilen_aday_id := mevcut_aday.aday_id;
        yaya_nufus := mevcut_aday.net_yaya;
        trafik_carpani := mevcut_aday.trafik_skoru;
        toplam_skor := mevcut_aday.max_skor;
        RETURN NEXT;
 
        UPDATE temp_kapi_durum k SET kapsandi_mi = TRUE
        WHERE ST_DWithin(k.geom_metric, mevcut_aday.geom_metric, etki_yaricapi)
          AND k.kapsandi_mi = FALSE;
 
        i := i + 1;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 5. YÖN VE GÖRÜNÜRLÜK FONKSİYONLARI[cite: 8]
CREATE OR REPLACE FUNCTION yonlu_kapsama(
    pano geometry, yon numeric, yaricap numeric, aci_genisligi numeric
) RETURNS numeric AS $$
    SELECT COALESCE(sum(k.nufus_yuku), 0)
    FROM geokapi k
    WHERE ST_DWithin(k.geom_metric, pano, yaricap)
      AND abs(
          ((degrees(ST_Azimuth(pano, k.geom_metric))
            - yon + 540)::numeric % 360) - 180
      ) > (180 - aci_genisligi / 2);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION gorunur_kapsama(
    pano geometry, yon numeric, yaricap numeric, aci_genisligi numeric
) RETURNS numeric AS $$
    SELECT COALESCE(sum(k.nufus_yuku), 0)
    FROM geokapi k
    WHERE ST_DWithin(k.geom_metric, pano, yaricap)
      AND ST_Distance(k.geom_metric, pano) > 5
      AND abs(
          ((degrees(ST_Azimuth(pano, k.geom_metric))
            - yon + 540)::numeric % 360) - 180
      ) > (180 - aci_genisligi / 2)
      AND NOT EXISTS (
          SELECT 1 FROM yapi b
          WHERE ST_Intersects(
              b.geom_metric,
              ST_LineSubstring(ST_MakeLine(pano, k.geom_metric), 0.02, 0.90))
      );
$$ LANGUAGE sql STABLE;

-- 6. KARAR DESTEK TABLOSU (QGIS GÖRÜNÜMÜ)[cite: 8]
CREATE VIEW v_pano_detay AS
SELECT s.sira,
    CASE
        WHEN s.sira = 1             THEN 'Zirve lokasyon'
        WHEN s.sira BETWEEN 2 AND 3 THEN 'Ikincil odak'
        WHEN s.sira BETWEEN 4 AND 5 THEN 'Bolgesel dagilim'
        WHEN s.sira BETWEEN 6 AND 8 THEN 'Transit baglanti'
        ELSE 'Tamamlayici halka'
    END AS secim_nedeni,
    m.adi_numarasi AS mahalle,
    y.yol_adi, y.fclass AS yol_sinifi,
    kp.hane_sayisi, kp.bina_sayisi, kp.brut_nufus,
    round(s.yaya_nufus) AS net_nufus,
    kp.brut_nufus - round(s.yaya_nufus) AS cakisma_kaybi,
    round(100.0 * s.yaya_nufus / NULLIF(kp.brut_nufus, 0), 1) AS ozgunluk_yuzde,
    s.trafik_carpani, round(s.toplam_skor) AS toplam_skor,
    s.geom_metric
FROM secilen_noktalar_trafikli s
LEFT JOIN LATERAL (
    SELECT count(k.tid) AS hane_sayisi,
           count(DISTINCT k.yapi_id) AS bina_sayisi,
           round(sum(k.nufus_yuku)) AS brut_nufus
    FROM geokapi k
    WHERE ST_DWithin(k.geom_metric, s.geom_metric, 150)
) kp ON true
LEFT JOIN aktar_geomahalle m ON ST_Intersects(s.geom_metric, m.geom_metric)
LEFT JOIN LATERAL (
    SELECT o.yol_adi, o.fclass FROM osm_yol o
    ORDER BY s.geom_metric <-> o.geom_metric LIMIT 1
) y ON true;
