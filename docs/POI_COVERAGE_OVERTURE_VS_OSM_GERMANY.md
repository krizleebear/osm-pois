# POI Coverage Comparison: Overture Places vs. OSM Parquet (Germany)

*Date: September 2026*  
*Datasets analyzed:*
* **Overture Places**: Official Release `2026-08-19.0`, `theme=places / type=place`, filtered for country `DE` (S3 `overturemaps-us-west-2`)
* **OSM Places Parquet**: Generated from full OpenStreetMap PBF using DuckDB & spatial pipeline (`DE_germany.places.parquet`)

---

## 1. Executive Summary

| Metric | OSM Parquet (`DE_germany`) | Overture Places (Germany) | Ratio / Difference |
| :--- | :---: | :---: | :---: |
| **Total POI Count** | **1,620,412** | **2,974,885** | 1 : 1.83 *(Overture +83%)* |
| **Distinct Categories** | **2,625** | **1,729** | OSM is significantly more granular |
| **Uncategorized POIs (`NULL`)** | **0 (0.0%)** | **155,216 (5.2%)** | Overture contains 155k unclassified POIs |
| **Shared Categories** | 498 | 498 | Core standard taxonomy overlap |

### Key Takeaways
1. **Consumer POI Parity (Gastro, Daily Retail, Pharmacy)**:
   For core everyday consumer venues (restaurants, bakeries, cafes, fashion stores, pharmacies), coverage between OSM and Overture is near 1:1 parity. OSM data quality often shows higher accuracy against physical ground truth (e.g., ~15.8k pharmacies in OSM vs. 17.5k real-world German pharmacies vs. 19.6k duplicate-prone entries in Overture).
2. **The "Overture Surplus" (Where the +1.35M comes from)**:
   Over **56% of Overture's German POIs originate from Meta (Facebook/Instagram business pages)** and another **20% from Microsoft Bing / directory listings**. These represent non-consumer B2B entities, freelancers, commercial contractors, and digital business presences that are rarely mapped on OpenStreetMap.
3. **OSM Dominance (Civic Infrastructure & Mobility)**:
   OpenStreetMap vastly outclasses Overture in public infrastructure, micro-mobility, renewable transport (EV charging: 35.8k vs. 8.3k), postal facilities (70.7k post boxes vs. 0), recycling, monuments, and municipal facilities.

---

## 2. Overture Data Source Breakdown (Germany)

Querying `sources[1].dataset` on Overture's 2,974,885 German places reveals that OpenStreetMap is **not used directly as a primary POI source** by Overture in Germany. Instead, Overture relies on social and directory crawls:

| Primary Source Dataset | POI Count | Share (%) | Description / Origin |
| :--- | :---: | :---: | :--- |
| **Meta** | 1,674,608 | 56.3 % | Facebook Pages & Instagram Business profiles |
| **Foursquare** | 650,218 | 21.9 % | Foursquare check-in & business venue database |
| **Microsoft** | 587,259 | 19.7 % | Bing Places, web scrapes & commercial directories |
| **AllThePlaces** | 38,105 | 1.3 % | Chain store web-scraper database |
| **Krick** | 16,943 | 0.6 % | German Yellow Pages (*Gelbe Seiten*) publisher |
| **PinMeTo** | 5,757 | 0.2 % | Multi-location brand management provider |
| **DAC** | 1,995 | 0.1 % | Digital advertising & listings directory |

---

## 3. Sector-by-Sector Breakdown

### A. Gastronomy & Food & Beverage
| Category | OSM Count | Overture Count | Delta (OSM - Overture) | Notes |
| :--- | :---: | :---: | :---: | :--- |
| `restaurant` | 37,887 | 42,864 | -4,977 | High parity; Overture splits more by cuisine |
| `fast_food_restaurant` | 35,596 | 7,847 | **+27,749** | OSM captures kebab shops, snack bars, food stalls far better |
| `bakery` | 29,587 | 31,768 | -2,181 | Almost identical (~30k bakeries nationwide) |
| `cafe` | 30,008 | 25,880 | **+4,128** | OSM community maintains comprehensive cafe coverage |
| `german_restaurant` | 7,395 | 22,525 | -15,130 | Overture assigns cuisine directly as primary category |
| `italian_restaurant` | 9,789 | 16,028 | -6,239 | Cuisine tag prioritization in Overture |
| `pub` | 13,995 | 5,173 | **+8,822** | Traditional local pubs strongly mapped in OSM |
| `bar` | 7,977 | 14,027 | -6,050 | Nightlife venues often cataloged on Facebook |
| `beer_garden` | 2,320 | 2,149 | **+171** | Excellent alignment |
| `ice_cream_parlor` | 5,683 | 3,112 | **+2,571** | Seasonal ice cream shops well-covered in OSM |

### B. Retail & Daily Needs
| Category | OSM Count | Overture Count | Delta (OSM - Overture) | Notes |
| :--- | :---: | :---: | :---: | :--- |
| `clothing_store` | 31,338 | 36,862 | -5,524 | Close parity |
| `supermarket` | 16,718 | 0 | **+16,718** | Taxonomy mismatch: Overture does not use `supermarket` |
| `grocery_store` | 70 | 42,748 | -42,678 | Overture pools supermarkets into `grocery_store` |
| `convenience_store` | 8,373 | 3,803 | **+4,570** | Kiosks, Spätis, corner shops strongly mapped in OSM |
| `florist` | 8,660 | 5,973 | **+2,687** | Flower shops well cataloged in OSM |
| `furniture_store` | 3,980 | 13,078 | -9,098 | Meta pages capture small interior studios |
| `shopping` (generic) | 1,747 | 31,549 | -29,802 | Overture has large numbers of generic bucket tags |

### C. Mobility, Vehicles & Transport
| Category | OSM Count | Overture Count | Delta (OSM - Overture) | Notes |
| :--- | :---: | :---: | :---: | :--- |
| `ev_charging_station` | 35,863 | 8,339 | **+27,524** | **OSM massive advantage**: Germany's charging network |
| `gas_station` | 10,955 | 25,344 | -14,389 | Reality: ~14.5k stations in DE. Overture has duplicates |
| `automotive_repair` | 13,698 | 30,850 | -17,152 | Local mechanics heavily indexed via Facebook/Bing |
| `car_dealer` | 0 | 23,714 | -23,714 | `shop=car` was not mapped in older export runs |
| `car_wash` | 3,092 | 3,714 | -622 | Strong alignment |
| `train_station` | 0 | 8,296 | -8,296 | Tagging updated in recent pipeline commit |

### D. Healthcare & Medicine
| Category | OSM Count | Overture Count | Delta (OSM - Overture) | Notes |
| :--- | :---: | :---: | :---: | :--- |
| `pharmacy` | 15,847 | 19,610 | -3,763 | Real ground truth: ~17,500. OSM is remarkably accurate |
| `concierge_medicine` / Doctors | 35,531 | 0 | **+35,531** | OSM `amenity=doctors` currently mapped to this category |
| `dentist` / `dental_clinic` | 15,510 *(clinic)* | 25,179 *(dentist)* | -9,669 | Taxonomy divergence (`dentist` vs `dental_clinic`) |
| `physical_therapy` | 8,751 | 25,283 | -16,532 | Physiotherapists maintain active social profiles |
| `hospital` | 341 | 7,156 | -6,815 | Overture counts hospital wards/departments as separate POIs |

### E. Public Infrastructure & Civic Life (OSM Outperformance)
| Category | OSM Count | Overture Count | Delta (OSM - Overture) | Notes |
| :--- | :---: | :---: | :---: | :--- |
| `visitor_center` / Tourist info | 175,749 | 641 | **+175,108** | Info boards, hiking points, trail maps |
| `sculpture_statue` / Monuments | 71,403 | 157 | **+71,246** | Public art, statues, historic memorials |
| `post_box` | 70,775 | 0 | **+70,775** | Deutsche Post drop boxes (non-commercial) |
| `recycling_center` / Glass bins | 21,897 | 1,671 | **+20,226** | Municipal public utility infrastructure |
| `package_locker` (Packstation) | 13,136 | 3,559 | **+9,577** | Automated lockers (DHL, Amazon, etc.) |
| `fire_station` | 7,751 | 0 | **+7,751** | Volunteer & municipal fire stations |
| `police_station` | 1,913 | 0 | **+1,913** | Federal & state police stations |
| `library` | 4,674 | 4,339 | **+335** | High alignment across municipal libraries |

### F. Commercial & B2B Surplus in Overture
The largest contributor to Overture's numerical lead is B2B, craft, and commercial service listings mined from Meta and Microsoft:
* `professional_services`: 84,565
* `community_services_non_profits`: 45,949
* `advertising_agency`: 35,853 (OSM: 2,361)
* `building_supply_store`: 33,202 (OSM: 0)
* `contractor` (tradesmen, renovation, construction): 22,769 (OSM: 0)
* `real_estate_agent`: 24,456 (OSM: 2,147)
* `engineering_services`: 21,961 (OSM: 351)
* `church_cathedral`: 21,839 (OSM: 0 — pending `place_of_worship` mapping)

---

## 4. Recommendations for Pipeline Harmonization

1. **Category Mapping Alignment**:
   * **Supermarkets**: Map `shop=supermarket` to `grocery_store` (or maintain `supermarket` if granularity preservation is preferred per `AGENTS.md`).
   * **Hairdressers**: Harmonize `shop=hairdresser` (currently `barber`, 36.4k) with `hair_salon` (Overture has 42k `hair_salon` and only 5k `barber`).
   * **Places of Worship**: Map `amenity=place_of_worship` + `religion=christian` to `church_cathedral` (~22k POIs currently unextracted).
   * **Medical Practitioners**: Map `amenity=doctors` to `physicians_and_surgeons` / `health_and_medical` instead of `concierge_medicine`, and `amenity=dentist` to `dentist` rather than `dental_clinic`.
2. **B2B / Office Inclusion**:
   * Include `craft=*` and `office=*` attributes more broadly if narrowing the volume gap against commercial listings is desired.
