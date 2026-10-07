# INF915 — Modèle de données (Mermaid)

Source : `inf915_modele_demande_oracle11.sql`. 7 tables, 2 tables temporaires.

Lecture :
- trait plein = clé étrangère déclarée ;
- trait pointillé = lien logique, sans clé étrangère (identifiants Clarify ou journal purgeable) ;
- les identifiants Clarify (`ID_ORGA_*`, `ID_*_SOURCE`, `ID_*_CIBLE`, `ID_CONTR_ITM`) pointent vers `SA.*`, hors de ce modèle.

```mermaid
erDiagram
    INF915_REF_OPERATION ||--o{ INF915_NOTIFICATIONS : "qualifie (etiquette)"
    INF915_NOTIFICATIONS ||--o{ INF915_ACTION        : "historique, cascade"
    INF915_NOTIFICATIONS ||--o{ INF915_OBJET_PARENT  : "objets parents, cascade"
    INF915_NOTIFICATIONS ||--o{ INF915_LIGNE         : "perimetre fige, cascade"
    INF915_NOTIFICATIONS ||--o{ INF915_CONTROLE      : "controles, cascade"
    INF915_NOTIFICATIONS ||--o{ INF915_EVENEMENT     : "journal, cascade"
    INF915_LIGNE         |o--o{ INF915_LIGNE         : "porteuse"
    INF915_ACTION        |o--o{ INF915_LIGNE         : "derniere relance"
    INF915_LIGNE         |o--o{ INF915_CONTROLE      : "controle de ligne, cascade"
    INF915_ACTION        |o--o{ INF915_CONTROLE      : "passe de controle"
    INF915_ACTION        |o--o{ INF915_EVENEMENT     : "action declencheuse"
    INF915_LIGNE         }o..o| INF915_EVENEMENT     : "ID_LIGNE sans FK"
    INF915_OBJET_PARENT  }o..o| INF915_EVENEMENT     : "ID_OBJET_PARENT sans FK"
    INF915_OBJET_PARENT  }o..o{ INF915_LIGNE         : "ID_*_SOURCE et ID_*_CIBLE"

    INF915_REF_OPERATION {
        VARCHAR2 CODE_OPERATION PK "40"
        VARCHAR2 LIBELLE "160, NOT NULL"
        VARCHAR2 ACTE_HISTORIQUE "60"
        NUMBER ACTIF "1, defaut 1"
    }

    INF915_NOTIFICATIONS {
        NUMBER ID_NOTIFICATION PK "TRG_INF915_NOTIF_BI"
        VARCHAR2 REFERENCE UK "TR-AAAA-NNNNNN"
        NUMBER ID_ORGA_SOURCE "OBJID Clarify"
        NUMBER ID_ORGA_CIBLE "NULL = conservee"
        VARCHAR2 MAILLE "MASSE, SELECTION"
        VARCHAR2 CODE_OPERATION FK "etiquette informative"
        DATE DATE_EFFET
        VARCHAR2 STATUT "10 statuts, trigger BU"
        NUMBER NB_LIGNES
        NUMBER NB_CONTRATS
        NUMBER NB_SI
        NUMBER NB_CF
        NUMBER NB_LOTS
        NUMBER NB_LIGNES_OK
        NUMBER NB_LIGNES_KO_METIER
        NUMBER NB_LIGNES_KO_TECH
        NUMBER NB_OBJETS_A_CREER
        NUMBER NB_OBJETS_CREES
    }

    INF915_ACTION {
        NUMBER ID_ACTION PK "TRG_INF915_ACTION_BI"
        NUMBER ID_NOTIFICATION FK
        VARCHAR2 TYPE_ACTION "8 types"
        VARCHAR2 ACTEUR "40"
        VARCHAR2 TYPE_ACTEUR "UTILISATEUR, SYSTEME"
        TIMESTAMP DATE_ACTION
        VARCHAR2 STATUT_AVANT
        VARCHAR2 STATUT_APRES
        NUMBER NB_LIGNES_VISEES
        VARCHAR2 PORTEE "TOUTES, ERREUR_TECH, ERREUR_METIER, SELECTION"
        VARCHAR2 MOTIF "500"
    }

    INF915_OBJET_PARENT {
        NUMBER ID_OBJET_PARENT PK "TRG_INF915_PARENT_BI"
        NUMBER ID_NOTIFICATION FK "UK avec TYPE_OBJET et ID_OBJET_SOURCE"
        VARCHAR2 TYPE_OBJET UK "CONTRAT, SI, CF, LOT"
        NUMBER ID_OBJET_SOURCE UK "OBJID Clarify"
        NUMBER NB_LIGNES
        VARCHAR2 TYPE_CIBLE "IDENTIQUE, EXISTANT, CREATION"
        NUMBER ID_OBJET_CIBLE "alimente par le worker si CREATION"
        VARCHAR2 STATUT "A_TRAITER, SANS_OBJET, CREE, REUTILISE, ERREUR"
        TIMESTAMP DATE_TRAITEMENT
        NUMBER NB_TENTATIVES
        VARCHAR2 CODE_ERREUR
        VARCHAR2 MSG_ERREUR "500"
    }

    INF915_LIGNE {
        NUMBER ID_LIGNE PK "TRG_INF915_LIGNE_BI"
        NUMBER ID_NOTIFICATION FK "UK avec ID_CONTR_ITM"
        NUMBER ID_CONTR_ITM UK "BdS1, OBJID Clarify"
        NUMBER ID_LIGNE_PORTEUSE FK "auto-reference"
        NUMBER ID_CONTRAT_SOURCE
        NUMBER ID_SI_SOURCE
        NUMBER ID_CF_SOURCE
        NUMBER ID_LOT_SOURCE
        VARCHAR2 STATUT_ACT_SOURCE "historise"
        VARCHAR2 STATUT_MAT_SOURCE "historise"
        NUMBER ID_CONTRAT_CIBLE
        NUMBER ID_SI_CIBLE
        NUMBER ID_CF_CIBLE
        NUMBER ID_LOT_CIBLE
        NUMBER ID_CONTR_ITM_CIBLE "BdS creee, idempotence"
        VARCHAR2 STATUT "A_TRAITER, EN_COURS, TRANSFEREE, ERREUR_METIER, ERREUR_TECHNIQUE"
        VARCHAR2 ETAPE
        NUMBER NB_TENTATIVES
        VARCHAR2 ID_WORKER "60"
        NUMBER ID_ACTION_RELANCE FK
        TIMESTAMP DATE_DEBUT
        TIMESTAMP DATE_FIN
        VARCHAR2 CODE_ERREUR
        VARCHAR2 MSG_ERREUR "500"
    }

    INF915_CONTROLE {
        NUMBER ID_CONTROLE PK "TRG_INF915_CTRL_BI"
        NUMBER ID_NOTIFICATION FK
        NUMBER ID_LIGNE FK "NULL = portee globale"
        NUMBER ID_ACTION FK
        VARCHAR2 CODE_CONTROLE
        VARCHAR2 NIVEAU "BLOQUANT, AVERTISSEMENT, INFO"
        VARCHAR2 RESULTAT "OK, KO, SANS_OBJET"
        VARCHAR2 PHASE "ACQUISITION, EXECUTION"
        VARCHAR2 MSG "500"
        TIMESTAMP DATE_CONTROLE
    }

    INF915_EVENEMENT {
        NUMBER ID_EVENEMENT PK "TRG_INF915_EVT_BI"
        NUMBER ID_NOTIFICATION FK
        NUMBER ID_LIGNE "sans FK, purgeable"
        NUMBER ID_OBJET_PARENT "sans FK, purgeable"
        NUMBER ID_ACTION FK
        VARCHAR2 ETAPE
        VARCHAR2 STATUT_AVANT
        VARCHAR2 STATUT_APRES
        VARCHAR2 CODE_ERREUR
        VARCHAR2 MSG "1000"
        VARCHAR2 ID_WORKER "60"
        TIMESTAMP DATE_EVT
    }

    INF915_TMP_LIGNE {
        VARCHAR2 MASTER_ID "60, rapproche de X_AV_ID_EDS"
        NUMBER ID_CONTRAT_SOURCE
        NUMBER ID_SI_SOURCE
        NUMBER ID_CF_SOURCE
    }

    INF915_TMP_CIBLE {
        VARCHAR2 TYPE_OBJET "CONTRAT, SI, CF"
        NUMBER ID_OBJET_SOURCE
        VARCHAR2 TYPE_CIBLE "EXISTANT, CREATION"
        NUMBER ID_OBJET_CIBLE "NULL si CREATION"
    }
```

## Notes

- `INF915_TMP_LIGNE` et `INF915_TMP_CIBLE` : tables temporaires `ON COMMIT PRESERVE ROWS`, sans lien déclaré. Le service web les alimente, puis `INF915_PY.PR_CREER_DEMANDE` les lit et les purge. Elles produisent les lignes de `INF915_LIGNE` et `INF915_OBJET_PARENT`.
- Vues : `INF915_V_VOLUMETRIE` (compteurs recalculés), `INF915_V_JALON`, `INF915_V_SUIVI` (écran de suivi). Elles lisent les tables ci-dessus et ne portent aucune donnée propre.
- Cycle de vie de `STATUT` (`INF915_NOTIFICATIONS`) : 10 statuts, 19 transitions imposées par `TRG_INF915_NOTIF_BU`.
- Index uniques fonctionnels sur `INF915_ACTION` : une seule `CREATION` et une seule `ANNULATION` par demande.
