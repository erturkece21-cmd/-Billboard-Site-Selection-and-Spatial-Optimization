<img width="1498" height="812" alt="QGIS" src="https://github.com/user-attachments/assets/5065531a-02e3-425d-8b3c-dcfdd0385977" />
# CBS Tabanlı Billboard Yer Seçimi ve Mekansal Optimizasyon

Kadıköy ilçesinde reklam panosu yer seçimini bir mekansal karar destek
problemi olarak modelleyen, tamamı veri tabanı içinde çözülen analiz.
Netcad Yazılım A.Ş. zorunlu yaz stajı kapsamında geliştirildi (2026).


## 📌 Yaklaşım
- Mahalle nüfusu, adres (kapı) noktaları kullanılarak **dasimetrik** yöntemle adres düzeyine indirgendi.
- Aday konumlar yol ekseni üzerinde `ST_Segmentize` ile 10 m aralıkla üretildi (~25.000 aday); yol hiyerarşisine göre hareketlilik çarpanı atandı.
- Optimum pano seti **açgözlü küme kaplama (greedy set cover)** ile seçildi; aynı kişinin iki kez sayılması ve panoların yan yana dikilmesi engellendi.
- Duyarlılık, marjinal katkı, yön/görünürlük ve Voronoi analizleriyle test edildi.

## 📊 Öne Çıkan Bulgu
Dairesel 150 m görünürlük varsayımıyla 10 pano 40.830 kişiye ulaşıyor görünürken; yön kısıtı ve bina engelleri hesaba katıldığında bu sayı **1.180'e** (kapsama oranı %2.9) düşmektedir.

## 🛠️ Teknolojiler
PostgreSQL 18.6 · PostGIS 3.6.2 · GDAL 3.9.2 · QGIS · EPSG:5254

## 📂 Veri ve Dosya Yapısı
Kurum verisi (adres, bina, mahalle nüfusu) gizlilik nedeniyle repoya dahil
edilmemiştir. Yol ağı: OpenStreetMap / Geofabrik (ODbL).

* `analiz_sorgulari.sql`: Nüfus dağıtımı, aday nokta üretimi, açgözlü küme kaplama algoritması ve yön/görünürlük fonksiyonlarını içeren temel SQL komutları.
* `QGIS.webp`: Analiz sonucunda elde edilen optimum konumların QGIS üzerindeki kartografik sunumu.

## ⚙️ Proje İş Akışı (Workflow)

```text
📦 Kadikoy-Billboard-Optimization
├── 1. Veri Tanıma ve Hazırlık
│   ├── Kurum ve OSM (Geofabrik) verilerinin kalite denetimi ve entegrasyonu
│   └── Mekansal analizler için EPSG:5254 (TM30) metrik koordinat sistemine dönüşüm
├── 2. Dasimetrik Nüfus Modellemesi
│   └── Kaba mahalle nüfuslarının adres (kapı) noktalarına oransal olarak dağıtılması
├── 3. Çözüm Uzayı ve Ağırlıklandırma
│   ├── Yol ekseni üzerinde 10 metre aralıklarla 25.350 aday konum üretimi (ST_Segmentize)
│   └── Yol hiyerarşisine göre adaylara hareketlilik çarpanı (1.2, 1.5, 2.0) atanması
├── 4. Mekansal Optimizasyon
│   ├── Açgözlü Küme Kaplama (Greedy Set Cover) algoritmasının veritabanı içinde çalıştırılması
│   └── İstatistiksel (mükerrer sayım) ve fiziksel (250m kısıtı) yamyamlık hatalarının engellenmesi
├── 5. Doğrulama ve İleri Analizler
│   ├── ST_LineSubstring ve 120° görüş açısı ile gerçekçi görünürlük ve bina engeli hesabı
│   ├── Parametre duyarlılığı, doygunluk eğrisi ve Voronoi (hinterland) poligon analizleri
└── 6. Kartografya ve Karar Destek
    └── Optimum lokasyonların QGIS'te sembolojik sunumu ve karar destek tablolarının üretilmesi
