# Direct depuis NAIADES

library(downloader)

library(tidyverse)

library(utils)

library(sf)

library(data.table)

`%notin%` <- Negate(`%in%`)

options(timeout = 3600)

download(
  "https://naiades.eaufrance.fr/reports/reportsperyear/HB/Naiades_Export_France_Entiere_HB.zip",
  dest = "data/dataset.zip",
  mode = "wb"
)
unzip("data/dataset.zip",
      exdir = "./data")
file.remove("data/cep.csv")
file.remove("data/operation.csv")
file.remove("data/resultat.csv")
file.remove("data/DescriptionDonneesHB.pdf")

france_metropolitaine <- st_read("data/FRA_adm0.shp")

Diatom <- as_tibble(fread("data/fauneflore.csv")) %>%
        dplyr::select(
          "CODE_STATION" = CdStationMesureEauxSurface,
          "Nom_groupe_taxo" = LbSupport,
          "DATE" = DateDebutOperationPrelBio,
          "SANDRE" = CdAppelTaxon,
          "Nom_latin_taxon" = NomLatinAppelTaxon,
          "RESULTAT" = RsTaxRep,
          "Code_groupe_taxo" = CdSupport
        ) %>%
        dplyr::filter(Code_groupe_taxo == 10) %>%
        dplyr::select(-Code_groupe_taxo) %>%
        distinct(CODE_STATION,
                 Nom_groupe_taxo,
                 DATE,
                 SANDRE,
                 Nom_latin_taxon,
                 RESULTAT) %>%
        dplyr::select(-Nom_groupe_taxo) %>%
        arrange(DATE,
                CODE_STATION,
                Nom_latin_taxon, RESULTAT) %>%
        dplyr::filter(RESULTAT != 0) %>%
        mutate(DATE = as.Date(DATE)) %>%
        arrange(DATE) %>%
        group_by(CODE_STATION, DATE) %>%
        dplyr::mutate(tot = sum(RESULTAT)) %>%
        ungroup() %>%
        dplyr::mutate(RESULTAT = (RESULTAT / tot) * 1000) %>%
        dplyr::mutate(RESULTAT = round(RESULTAT, 2)) %>% # Passage des abondances en relative pour 1000
        dplyr::select(-tot) %>%
        left_join(read.csv2("data/CODE_OMNIDIA_traites.csv", stringsAsFactors = FALSE),
                  by = "SANDRE") %>%
        dplyr::filter(SANDRE != 0) %>%
        rename(taxon = code_omnidia) %>%
        mutate(CODE_STATION = str_remove(CODE_STATION, "^0+")) %>%
        left_join(
          as_tibble(
            read.csv2(
              "data/stations.csv",
              stringsAsFactors = FALSE,
              quote = "",
              na.strings = c("", "NA")
            )
          ) %>% select(
            CODE_STATION = CdStationMesureEauxSurface,
            commune = LbCommune,
            longitude = CoordXStationMesureEauxSurface,
            latitude = CoordYStationMesureEauxSurface,
            type = CodeTypEthStationMesureEauxSurface
          ) %>%
            mutate(
              longitude = as.numeric(longitude),
              latitude = as.numeric(latitude),
              type = ifelse(type == 2, "cours d'eau", "plan d'eau")
            ) %>%
            dplyr::filter(!is.na(longitude)) %>%
            dplyr::filter(longitude > 0) %>%
            mutate(CODE_STATION = str_remove(CODE_STATION, "^0+")),
          by = "CODE_STATION"
        ) %>%
        drop_na() %>%
        sf::st_as_sf(coords = c("longitude", "latitude"), crs = 2154) %>%
        st_transform(geometry, crs = 4326) %>%
        st_intersection(france_metropolitaine) %>%
        st_jitter(factor = 0.00001) %>%
        dplyr::select(CODE_STATION,
                      DATE,
                      SANDRE,
                      Nom_latin_taxon,
                      RESULTAT,
                      taxon,
                      commune,
                      type) %>%
        tidyr::extract(geometry, c("long", "lat"), "\\((.*), (.*)\\)", convert = TRUE) %>%
        left_join(as_tibble(
          read.csv2("data/table_transcodage.csv", stringsAsFactors = FALSE)
        ) %>%
          dplyr::select(taxon = "abre", True_name = "CodeValid"),
        by = "taxon") %>%
        mutate(taxon = if_else(is.na(True_name) == T, taxon, True_name)) %>%
        dplyr::select(-True_name) %>%
        dplyr::filter(!is.na(taxon)) %>%
        left_join(
          read.csv2("data/table_transcodage.csv", stringsAsFactors = FALSE) %>%
            select(taxon = CodeValid, full_name = name_valid) %>% distinct() %>%
            mutate(full_name = sub("\\_g.*", "", full_name)),
          by = "taxon"
        ) %>%
        mutate(full_name = str_replace_all(full_name, "[^[:alnum:]]", " ")) %>%
        mutate(full_name = paste0(full_name, " ", "(", taxon, ")")) %>%
        mutate(lon = round(long, 10), lat = round(lat, 10)) %>%
        left_join(
          read.csv2("data/table_transcodage.csv", stringsAsFactors = FALSE) %>%
            select(abre, name, taxon = CodeValid) %>% unique() %>%
            group_by(taxon) %>% dplyr::filter(abre %notin% taxon) %>% mutate(list = paste0(abre, " ", sub("\\_g.*", "", name))) %>%
            mutate(taxons_apparies = paste(list, collapse = " / ")) %>%
            select(-abre,-name,-list) %>% distinct(),
          by = "taxon"
        ) %>% 
        mutate(CodeValid = full_name) %>%
        separate_rows(taxons_apparies, sep = " / ") %>%
        group_by(CodeValid) %>%
        mutate(taxons_apparies = ifelse(is.na(taxons_apparies) == TRUE, "Aucun", paste0(str_sub(taxons_apparies,  start = 6)," (", str_sub(taxons_apparies,  start = 1, end = 4),")"))) %>%
        group_by(full_name) %>%
        mutate(grp = cur_group_id()) %>%
        mutate(taxons_apparies = ifelse(taxons_apparies == "Aucun", taxons_apparies, paste0(full_name, " / ", taxons_apparies))) %>%
        separate_rows(taxons_apparies, sep = " / ") %>%
        distinct(taxons_apparies, CODE_STATION, DATE, .keep_all = TRUE) %>%
        mutate(full_name = taxons_apparies) %>%
        ungroup() %>%
        group_by(grp, DATE, CODE_STATION) %>%
        mutate(taxons_apparies = map_chr(row_number(), ~paste(unique(taxons_apparies[-.x]), collapse = " / "))) %>%
        ungroup() %>%
        dplyr::mutate(taxons_apparies = ifelse(taxons_apparies == "", "Aucun", taxons_apparies)) %>%
        mutate(full_name = ifelse(full_name == "Aucun", paste0(Nom_latin_taxon, " (", taxon,")"), full_name)) 


save(Diatom, file = paste0("data_raw/data_", make.names(Sys.time()), ".Rda"))

file.remove("data/stations.csv")
file.remove("data/fauneflore.csv")

