# INF915 — Transfert de parc unifié SFR

Contexte complet du projet, à lire avant toute intervention sur le code.

---

## 1. Le projet en deux paragraphes

SFR dispose aujourd'hui de huit actes distincts pour déplacer des lignes de service d'une
structure client vers une autre : Fusac, CTI, Structure Fact, Transfert Administratif,
Transfert Administratif MOVE, Changement de CF, Changement Payeur, Changement de
Titulaire. Chacun a son écran, son batch, ses règles, et vingt ans de correctifs
sédimentés. Le conseiller doit savoir lequel choisir avant même de décrire ce qu'il veut
faire.

Le projet remplace ces huit actes par **un parcours unique** dans RC One / RC 360. Le
conseiller délimite un périmètre source, décrit une destination, et le système en déduit
l'acte. L'exécution est reprise dans un package PL/SQL et un orchestrateur Python, en
remplacement des batchs ClearBasic et Pro*C actuels.

---

## 2. Les livrables

| Fichier | Rôle |
|---|---|
| `inf915_modele_demande_oracle11.sql` | modèle de données : 7 tables, 2 tables temporaires, 7 triggers, 3 vues |
| `inf915_py.sql` | package `INF915_PY`, point d'entrée unique du service web et des workers |
| `inf915_orchestrateur.py` | orchestrateur batch, lance les procédures du package |
| `inf915.ini` | configuration de l'orchestrateur |
| `rcone_transfert_parc.html` | maquette interactive du parcours, six écrans |

Ordre d'installation : le modèle, puis le package. L'orchestrateur et son `.ini` se
déposent dans le même répertoire côté batch, le `.ini` en `chmod 600`.

---

## 3. Modèle de données

### 3.1 Les sept tables

```
INF915_REF_OPERATION    libellés des 7 opérations déduites, pour le reporting
INF915_NOTIFICATIONS    l'en-tête d'une demande
INF915_ACTION           historique de la demande : création, validation, annulation, relance
INF915_OBJET_PARENT     objets parents du périmètre et leur cible
INF915_LIGNE            le périmètre figé, une ligne par BdS1
INF915_CONTROLE         résultats des contrôles
INF915_EVENEMENT        journal technique ligne par ligne
```

Plus deux tables temporaires qui portent le contrat d'entrée du service web :

```
INF915_TMP_LIGNE    MASTER_ID, ID_CONTRAT_SOURCE, ID_SI_SOURCE, ID_CF_SOURCE
INF915_TMP_CIBLE    TYPE_OBJET, ID_OBJET_SOURCE, TYPE_CIBLE, ID_OBJET_CIBLE
```

### 3.2 Règle de normalisation

**Seuls les identifiants techniques sont stockés.** Les libellés, numéros de contrat,
SITE_ID et noms de lot restent dans le référentiel Clarify et sont résolus à l'affichage.
Conséquence assumée : la restitution d'une demande ancienne affiche les libellés
d'aujourd'hui.

Deux exceptions délibérées :

- les **compteurs** de `INF915_NOTIFICATIONS`, pour que l'écran de suivi n'agrège pas à
  chaud. Toujours mis à jour en incrémental. La vue `INF915_V_VOLUMETRIE` donne
  l'équivalent recalculé ;
- les **statuts source** de `INF915_LIGNE`, historisés parce que ce sont les valeurs qui
  ont servi aux contrôles et qu'elles changent entre la création et l'exécution.

### 3.3 Cycle de vie d'une demande

Dix statuts. Une demande n'existe en base que si elle est valide : les brouillons vivent
dans l'application appelante et les contrôles sont joués en amont par le service web
synchrone. Écrire la demande vaut donc validation, d'où l'absence de `BROUILLON` et de
`CONTROLEE`.

```
          EN_ATTENTE ──────────────────────────────┐
               │                                    │
               ▼                (aucun objet à créer)
       EN_COURS_PARENTS                             │
               │                                    │
      ┌────────┴─────────┐                          │
      ▼                  ▼                          │
   PARENTS_CREES ◄─ PARENTS_EN_ERREUR               │
       │                  │  (correction, relance)  │
       │  POINT D'ARRÊT : feu vert du métier        │
       ▼                                            │
   EN_ATTENTE_TRT_LIGNES                            │
       │  (prise en charge d'un worker)             │
  ═════│════════════════════════════════════════════│═══════════
       │        FRONTIÈRE D'IRRÉVERSIBILITÉ         │
       ▼                                            ▼
   EN_COURS_LIGNES ──┬──► TRAITEE
          ▲          ├──► TRAITEE_PARTIELLE
          │          └──► EN_ERREUR
          └───────── (relance des lignes en échec)

   ANNULEE ◄── EN_ATTENTE, PARENTS_CREES, PARENTS_EN_ERREUR, EN_ATTENTE_TRT_LIGNES
               c'est-à-dire tous les statuts au-dessus de la frontière, et eux seuls.
```

**Le point d'arrêt `PARENTS_CREES` est le seul du cycle.** La phase séquentielle crée des
contrats, des sites et des lots qui n'existaient pas ; ces objets sont vérifiables et
corrigeables tant qu'aucune BdS n'a bougé. Aucun worker ne franchit ce jalon tout seul :
il faut une action humaine, tracée sous le type `VALIDATION_PARENTS`.

Exception : quand `NB_OBJETS_A_CREER` vaut zéro, il n'y a rien à vérifier et la demande
passe directement de `EN_ATTENTE` à `EN_COURS_LIGNES`. Le trigger
`TRG_INF915_NOTIF_BU` autorise ce raccourci pour ce seul cas et fait respecter les
dix-neuf transitions.

### 3.4 Statuts de ligne

Cinq valeurs : `A_TRAITER`, `EN_COURS`, `TRANSFEREE`, `ERREUR_METIER`,
`ERREUR_TECHNIQUE`. Pas de statut de contrôle : une ligne n'entre dans la demande que si
elle est éligible. `ERREUR_METIER` couvre le cas où le parc a changé entre la création et
la date d'effet.

---

## 4. Le package INF915_PY

Point d'entrée unique. Organisé en sections numérotées.

| Section | État |
|---|---|
| 1. Qualification de l'opération | implémentée |
| 2. Création de la demande | implémentée |
| 3. Création des objets cibles | implémentée |
| 4. Transfert des lignes | implémentée |
| 5. Contrôles d'exécution | emplacement réservé |

### 4.1 Règles de codage, non négociables

- **Aucun SQL dynamique.** Pas d'`EXECUTE IMMEDIATE`, pas de `DBMS_SQL`. Les copies
  d'objets passent par `%ROWTYPE` : `SELECT * INTO l_row`, réécriture des champs
  concernés, `INSERT ... VALUES l_row`. Le compilateur vérifie ainsi chaque nom de
  colonne réécrit ; un renommage casse la compilation au lieu de produire une erreur en
  production.
- **Aucune dépendance à `GESTION_SERVICE_GENERIQUE_PKG`**, qui n'est pas pérenne. Ce
  package sert de référence de lecture, pas de bibliothèque.
- **Seuls objets du socle autorisés** : `SA.PROC_X_AV_GETNEXTOBJID_II`, `_III`,
  `SA.GETCLARIFYNEXTID`, `SA.FUNC_X_AV_GETNEXTSITE_ID`, `SA.FUNC_GET_ID_IDS`.
- **Les blocs `EXCEPTION` ne se mettent qu'aux frontières de transaction.** Une procédure
  qui ne peut ni valider ni annuler laisse remonter. Un `WHEN OTHERS` qui ne sait que
  journaliser puis relancer finit par avaler une erreur.
- **Oracle 11g.** Pas de colonne `IDENTITY`, pas de `IS JSON`, pas de `SKIP LOCKED`, pas
  de `FETCH FIRST`. Identifiants sous trente caractères.

### 4.2 Les objets publics

```
-- Section 1 : qualification
FN_CODE_OPERATION (p_id_notification) RETURN VARCHAR2
PR_MAJ_CODE_OPERATION (p_id_notification)
FN_QUALIFIER_EN_ATTENTE (p_depuis DATE) RETURN NUMBER
FN_NB_MODIFIES / FN_NB_CIBLES

-- Section 2 : création, appelée par le service web
PR_CREER_DEMANDE (p_id_orga_source, p_id_orga_cible, p_maille, p_date_effet, p_acteur,
                  po_id_notification OUT, po_code_erreur OUT, po_msg_erreur OUT)

-- Section 3 : objets cibles, phase séquentielle
FN_NOUVEAU_SITE_ID / FN_CREER_CONTRAT / FN_CREER_SITE / FN_CREER_LOT
FN_CIBLE / PR_CREER_OBJETS_PARENTS

-- Section 4 : lignes, phase parallèle
PR_DEBUT_LIGNES / PR_TRANSFERER_BDS1 / PR_TRAITER_LIGNE
PR_LIBERER_LIGNES / PR_CLOTURER
```

### 4.3 `PR_CREER_DEMANDE`, contrat d'appel

Trois temps dans la même session :

1. le service insère le périmètre dans `INF915_TMP_LIGNE`, par lots JDBC ;
2. il insère dans `INF915_TMP_CIBLE` une ligne par objet parent qui change, les objets
   absents étant conservés tels quels ;
3. il appelle `PR_CREER_DEMANDE`.

La procédure purge les deux tables temporaires en sortie, succès ou échec, et valide ou
annule elle-même.

**Performance** : tout est ensembliste, aucune boucle, sept `INSERT ... SELECT` et un
`UPDATE`, quel que soit le volume. Dimensionné pour cent mille lignes.

La résolution du périmètre est une **égalité stricte sur quatre colonnes** :

```sql
JOIN SA.TABLE_CONTR_ITM i ON i.X_AV_ID_EDS       = t.MASTER_ID
                         AND i.CHILD2CONTR_ITM  IS NULL
                         AND i.X_AV_USED_BY2SITE = t.ID_SI_SOURCE
                         AND i.X_AV_BILL_TO2SITE = t.ID_CF_SOURCE
JOIN SA.TABLE_CONTR_SCHEDULE s ON s.OBJID = i.CONTR_ITM2CONTR_SCHEDULE
                              AND s.SCHEDULE2CONTRACT = t.ID_CONTRAT_SOURCE
WHERE NVL (i.X_AV_FLAG_TRANSFERT, 0) <> 1
  AND NVL (i.X_AV_STATUT_ACT, '~')   <> 'Résilié'
```

Le rattachement est porté par chaque ligne et non par un filtre global : le parcours
autorise plusieurs contrats, plusieurs SI et plusieurs CF, et un même master id peut
exister sur plusieurs BdS. Tout écart entre le nombre de lignes fournies et le nombre de
BdS1 retrouvées annule la demande.

Codes d'erreur fonctionnels retournés : `ORGA_SOURCE_ABSENTE`, `ORGA_CIBLE_EGALE_SOURCE`,
`MAILLE_INVALIDE`, `DATE_EFFET_ABSENTE`, `PERIMETRE_VIDE`, `CIBLE_EN_DOUBLE`,
`CIBLE_INVALIDE`, `PERIMETRE_INCOHERENT`, `ERREUR_TECHNIQUE`.

### 4.4 BdS1 et BdS2

Une ligne de service n'est pas une BdS mais un ensemble :

- **BdS1** : `TABLE_CONTR_ITM.CHILD2CONTR_ITM IS NULL`
- **BdS2** : `CHILD2CONTR_ITM` renseigné, pointant vers la BdS1

`INF915_LIGNE` ne porte que la BdS1. `PR_TRANSFERER_BDS1` crée la BdS1 puis boucle sur ses
BdS2. Toutes partagent le même IDS neuf et le même `P_LINE_NO` ; seul `LINE_NO_TXT` les
distingue : `12`, `12.1`, `12.2`.

Le lien vers la BdS d'origine est `X_AV_NEW2PREVIOUS`, porté par la BdS **cible** et
**uniquement par la BdS1**. `x_av_previous2new` n'est que le nom de parcours inverse.

### 4.5 Matrice de résiliation

Reprise intégralement de `ChmtCFPrice`, branche générale. Cinq cas, le premier qui
s'applique gagne :

| Condition | Statuts posés |
|---|---|
| `install_type = 'F'`, type ≠ NRC | Résilié · Prêt à Résilier · chg_end_dt |
| `install_type = 'IF'`, type ≠ NRC | idem + Réalisé · Traité · end_date |
| `install_type = 'I'`, gen_si = 1 | Résilié · Réalisé · Traité · chg_end_dt · end_date |
| `install_type = 'I'` | idem sans chg_end_dt |
| `cross_ref = 'CFE_TERM'`, type = NRC | Résilié · Réalisé · Traité · end_date |

Hors de ces cinq cas, la BdS source n'est pas résiliée. C'est le comportement d'origine,
pas un oubli.

---

## 5. L'orchestrateur Python

### 5.1 Contraintes de style, posées par le métier

- Python 3.7, pilote `cx_Oracle` avec un client Oracle 11.2 ou supérieur
- **aucune classe**
- **aucun paramètre de lancement** : tout est dans `inf915.ini`, cherché à côté du script
- **aucune notion de workflow ni d'étape**
- **aucune gestion de signal ni de `KeyboardInterrupt`** : le lancement est fait par un
  ordonnanceur de type VTOM
- formatage des chaînes avec `.format`, jamais avec `%s` ou `%d`

### 5.2 Ce qu'il fait

Deux passes, pilotées par deux requêtes disjointes, et rien d'autre.

```sql
-- Passe 1, séquentielle, une demande après l'autre
WHERE STATUT = 'EN_ATTENTE' AND NB_OBJETS_A_CREER > 0 AND DATE_EFFET <= TRUNC(SYSDATE)

-- Passe 2, N processus par demande
WHERE (STATUT = 'EN_ATTENTE_TRT_LIGNES'
       OR (STATUT = 'EN_ATTENTE' AND NB_OBJETS_A_CREER = 0))
  AND DATE_EFFET <= TRUNC(SYSDATE)
```

Les deux sélections sont disjointes : aucune demande ne peut être prise par les deux.
Le point d'arrêt métier n'est pas une règle codée, il découle du fait qu'une demande en
`PARENTS_CREES` n'apparaît dans aucune des deux requêtes.

**Une ligne par appel.** L'orchestrateur lit la liste des `ID_LIGNE` à traiter et en
soumet une par tâche au pool de processus. C'est le pool qui répartit : dès qu'un
processus a fini sa ligne, il prend la suivante. Aucune taille de lot à régler, et
l'équilibrage est exact même si une ligne porte une BdS et la suivante quinze.

La prise reste protégée côté base : `PR_TRAITER_LIGNE` ne traite la ligne que si elle est
encore en `A_TRAITER`, ce qui rend inoffensif un double lancement.

`nb_process = 20` par défaut. Les limites réelles sont le nombre de sessions de
l'instance et le coût d'ouverture des connexions sur un lot de petites demandes, pas le
nombre de cœurs : les processus attendent la base.

---

## 6. La maquette HTML

Six écrans, conformes à la charte fournie par l'UX designer.

```
1. Source        périmètre : organisation, contrats, SI, CF, puis sélection des lignes
2. Destination   un groupe de radios par axe, mapping N→N, date de traitement
3. Contrôles     compteurs transférables / bloquées, tableau des lignes bloquées
4. Validation    récapitulatif Source / Cible, panier à gauche, date d'effet à droite
5. Suivi         filtres, tableau des demandes, avancement, action unique par ligne
6. Détail        avancement global, compteurs, tableau des lignes
```

Jeu de données statique : 11 organisations, 14 contrats, 486 sites, 248 lots, 515 lignes.
**À conserver tel quel** lors de toute évolution de la maquette.

Règles d'interface arbitrées :

- l'organisation se change par un panneau de recherche ; la retirer vide le tableau, les
  filtres, le panier, et désactive le bouton suivant ;
- les trois axes acceptent plusieurs valeurs, par cases à cocher ; une liste vide vaut
  « tous » ; au-delà de douze valeurs un champ de recherche apparaît ;
- sur l'écran de suivi, **une seule icône d'action par ligne** : supprimer si le transfert
  n'a pas commencé (`EN_ATTENTE`), relancer s'il est terminé avec des lignes en erreur
  (`TRAITEE_PARTIELLE`, `EN_ERREUR`), rien sinon.

Piège rencontré : un `<select>` n'accepte que des `<option>`. Les trois filtres sont donc
des `<div>`. Un contrôle vérifie qu'aucun `<select>` ne reçoit autre chose.

---

## 7. Décisions arbitrées, à ne pas défaire

Chacune a été discutée et tranchée. Les réintroduire serait une régression.

**`FN_GARDE_ARBOR` est supprimée.** La garde d'origine de `ChmtCFPrice`,
`(x_av_arb_status <> 'CRE_ARB' OR x_av_arb_status <> 'MOD_ARB')`, est toujours vraie :
une valeur ne peut pas être différente des deux à la fois. L'intention était un `AND`. Le
garde-fou ne s'est jamais déclenché en vingt ans, il est donc retiré du code plutôt que
reproduit. Les conditions se réduisent à `install_type` et `x_av_type`.

**`X_AV_ARB_STATUS` n'est pas modifié sur la BdS source.** Les affectations à `CRE_ARB`
des branches `'F'` et `'IF'` sont commentées. On ne touche pas au statut Arbor lors d'une
résiliation. Les valorisations de la BdS cible, `Initialisation` et `RES_ARB`, restent
actives.

**`CODE_OPERATION` est une étiquette informative, nullable**, qualifiée après coup par le
worker. Elle ne pilote aucun traitement : le worker lit `INF915_OBJET_PARENT` et
`INF915_LIGNE`. `INF915_REF_OPERATION` n'a donc pas de colonne `NOM_PACKAGE` : il n'y a
pas un package par acte, il y a un seul traitement.

**Sept opérations, pas huit.** `TRANSFERT_LOT` est supprimé,
`TRANSFERT_INTER_CONTRAT` couvre l'ancien Fusac. Aucune notion de complétude de lot ou de
SI : savoir si un lot bascule en entier est une décision d'exécution, prise par le worker
avec le parc sous les yeux, pas une caractéristique de l'acte.

**Pas de SQL dynamique, pas de dépendance au package générique**, voir 4.1.

---

## 8. Sources d'origine analysées

Dans `/mnt/project` :

| Fichier | Ce qu'il apporte |
|---|---|
| `chmt_cf.cbs` | `ChmtCFPrice`, `CreateNewSchedule`, matrices de statuts, logique Arbor |
| `chTitulaireMobilePrice.cbs` | changement de titulaire, recherche par `x_av_id_eds` |
| `INB01_INF42_fusac.c` | batch Fusac, maille lot, quatre matrices de statuts |
| `verif_cf.sql` | contrôles de complétude d'un site de facturation |
| `GESTION_SERVICE_GENERIQUE_PKG.prc` | mécanismes d'allocation du socle, référence de lecture |

Colonnes Clarify attestées, à ne pas réinventer :

```
TABLE_CONTR_ITM        OBJID, X_AV_ID_EDS, CHILD2CONTR_ITM, CONTR_ITM2CONTR_SCHEDULE,
                       X_AV_USED_BY2SITE, X_AV_BILL_TO2SITE, X_AV_STATUT_ACT,
                       X_AV_STATUT_MAT, X_AV_FLAG_TRANSFERT, X_AV_ARB_STATUS,
                       X_AV_STATUS_C2A, X_AV_ETAT_ACT, X_AV_CODE_ETAT, P_LINE_NO,
                       LINE_NO, LINE_NO_TXT, X_AV_ID_IDS, X_AV_VERSION, CHG_START_DT,
                       CHG_END_DT, END_DATE, X_AV_OSS_ID_DEM, CONTR_ITM2MOD_LEVEL
TABLE_CONTR_SCHEDULE   OBJID, SCHEDULE2CONTRACT, SHIP_TO2SITE, BILL_TO2SITE,
                       SCHEDULE_ID, ITEM_COUNT, LAST_P_LINE_NO, X_AV_ID_INSTALL,
                       X_AV_ID_EXT_SITE, X_AV_STATUS, X_AV_VERSION, X_AV_DTFACT
TABLE_CONTRACT         OBJID, ID, S_ID, TITLE, S_TITLE, X_AV_BU, SELL_TO2BUS_ORG,
                       X_AV_NB_SCHED, X_AV_CURRENT_VERSION, X_AV_CONTRACT2VPN
TABLE_SITE             OBJID, GUID, SITE_ID, S_SITE_ID, NAME, PRIMARY2BUS_ORG,
                       CUST_BILLADDR2ADDRESS
TABLE_BUS_ORG          OBJID, ORG_ID, NAME, S_NAME, X_AV_BU, X_AV_NB_SITE_FACT
TABLE_BUS_SITE_ROLE    OBJID, ROLE_NAME, BUS_SITE_ROLE2SITE, BUS_SITE_ROLE2BUS_ORG
TABLE_CONTACT_ROLE     OBJID, ROLE_NAME, CONTACT_ROLE2SITE, CONTACT_ROLE2CONTACT,
                       CONTACT_ROLE2BUS_ORG, UPDATE_STAMP
TABLE_PART_NUM         X_AV_INSTALL_TYPE, X_AV_TYPE, X_AV_CROSS_REF, X_AV_GEN_SI
```

---

## 9. Points ouverts

**La propagation aval n'est pas écrite.** Événements accord cadre
`TABLE_X_AV_AC_EVENTS`, calcul PRI mobile `TABLE_X_AV_INF356_PRI_MOB_EVT`, notifications
EAI par `PROC_X_AV_EAI_INSERT_EVT_II`, réplication Arbor. C'est la section 5 du package.

**Trois noms déduits restent à confirmer par un `DESC`** : `TABLE_N_ATTRIBUTEVALUE` avec
`N_FOCUSLOWID`, `TABLE_CONTR_PR` avec `CONTR_PR2CONTR_ITM`, et `X_AV_NEW2PREVIOUS` sur
`TABLE_CONTR_ITM`.

**Deux valorisations en commentaire dans `PR_RESILIER_BDS`** : `X_AV_FLAG_TRANSFERT` et
`X_AV_NB_TRANSF`, non attestées dans la branche générale de `ChmtCFPrice`. La première
compte d'autant plus que `PR_CREER_DEMANDE` s'en sert pour écarter les BdS déjà
transférées : si notre transfert ne la pose pas, le filtre ne protège que du passé.

**Les cas particuliers des attributs de `ChmtCFPrice` ne sont pas repris** : repointage de
`N_TARGETLOWID` pour les attributs MSIM, motif de résiliation différent selon titulaire ou
payeur.

**`X_AV_CONTRACT2VPN`** pointe sur un VPN de l'organisation source. Sur un changement de
titulaire, le contrat créé référencerait un VPN étranger à son organisation.

**Centralisation vers un CF à créer** non représentable : dix sources en `CREATION` valent
dix créations distinctes. Correctif proposé en fin de section 3 du package, une colonne
`CLE_GROUPE_CIBLE`.

**Trois statuts sans action dans le suivi** : `PARENTS_CREES`, `PARENTS_EN_ERREUR` et
`EN_ATTENTE_TRT_LIGNES`, conséquence de la règle d'interface posée. À revoir si le métier
veut pouvoir annuler au point d'arrêt.

---

## 10. Conventions de travail

**Langue** : tout est en français, code, commentaires, messages d'erreur, noms de
variables. Les accents sont admis dans les commentaires PL/SQL et les libellés, pas dans
les messages `RAISE_APPLICATION_ERROR` ni les journaux Python.

**Ne jamais inventer une règle métier.** Si une valorisation n'est pas attestée dans les
sources d'origine, la laisser en commentaire avec la raison, comme pour
`X_AV_FLAG_TRANSFERT`. Un comportement plausible mais faux coûte infiniment plus cher
qu'un manque signalé.

**Reproduire fidèlement, y compris les défauts.** Quand l'existant contient un bug de
vingt ans, le reproduire et le signaler, ne pas le corriger en silence : la correction
change le comportement de tout le parc.

**Vérifier avant de livrer.** Chaque modification du package est contrôlée sur : tout
sous-programme appelé est défini, les signatures spécification et corps concordent, aucun
SQL dynamique, les `END` sont nommés. La maquette est rejouée sur toutes les
combinaisons d'organisation et de filtres.

**Préférer la simplicité.** Plusieurs abstractions ont été retirées en cours de route
parce qu'elles ne payaient pas leur coût : notion d'étape dans l'orchestrateur, classes
Python, paramètres de ligne de commande, gestion de signal, complétude de lot. En cas de
doute, la version la plus directe est la bonne.
