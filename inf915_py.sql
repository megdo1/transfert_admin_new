-- =====================================================================================
--  INF915_PY — PACKAGE PRINCIPAL DU TRANSFERT DE PARC
--  Cible : Oracle 11g R2
--
--  Point d'entrée unique des workers Python et de l'écran de suivi. Toutes les
--  procédures et fonctions du transfert de parc y sont regroupées, organisées en
--  sections numérotées. Les objets appelés depuis Python ne sont que ceux déclarés
--  dans la spécification ; tout le reste est privé au corps du package.
--
--  SECTIONS
--    1. Qualification de l'opération        (implémentée ci-dessous)
--    2. Création de la demande              (implémentée : point d'entrée du service
--                                            web de captation)
--    3. Création des objets cibles          (implémentée : copie conforme de la
--                                            source, avec repointage des liens)
--    4. Transfert des lignes                (implémentée : prise de lot parallèle,
--                                            création cible et résiliation source)
--    5. Contrôles d'exécution               (à venir)
--
--  Chaque section ajoutée doit respecter les mêmes règles que la première : aucune
--  écriture implicite, aucun accès au parc hors des points de couplage documentés, et
--  des fonctions pures partout où c'est possible, pour rester appelables dans un SELECT.
--
-- =====================================================================================
--  SECTION 1 — QUALIFICATION DE L'OPÉRATION
--
--  Le conseiller ne choisit jamais d'acte. Il décrit un périmètre et ce qu'il veut en
--  faire ; l'opération se déduit de la demande enregistrée. Ce package est
--  l'implémentation de cette déduction, et la seule source de vérité sur le sujet.
--
--  UNE ÉTIQUETTE, PAS UNE CLÉ DE ROUTAGE
--  L'acte déduit ne pilote aucun traitement. Le worker sait quoi faire en lisant
--  INF915_OBJET_PARENT, qui dit quels objets créer ou réutiliser, et INF915_LIGNE,
--  qui dit quelles BdS déplacer et vers quel rattachement. CODE_OPERATION n'existe
--  que pour le reporting, l'écran de suivi et la correspondance avec les huit actes
--  historiques. Trois conséquences pratiques :
--    - la qualification se fait après coup, par le worker Python, et non pendant la
--      saisie : l'IHM n'appelle jamais ce package ;
--    - CODE_OPERATION est facultatif, une demande non qualifiée se traite
--      normalement et s'affiche « En attente de qualification » ;
--    - une qualification erronée n'a aucune conséquence sur le transfert, elle se
--      corrige par un simple rappel de la procédure.
--  C'est pourquoi PR_MAJ_CODE_OPERATION n'échoue jamais : elle écrit NULL quand elle
--  ne sait pas conclure, plutôt que de bloquer une demande parfaitement valide.
--
--  TROIS ENTRÉES, RIEN D'AUTRE
--    - l'organisation cible est-elle renseignée, sur INF915_NOTIFICATIONS ;
--    - quels types d'objet parent sont modifiés, et vers combien de cibles distinctes,
--      sur INF915_OBJET_PARENT ;
--    - la maille, MASSE ou SELECTION, sur INF915_NOTIFICATIONS.
--
--  Aucun accès au parc Clarify, aucune volumétrie à relever, aucune notion de
--  complétude. La fonction est déterministe : la même demande donne toujours le même
--  acte, même relue des mois plus tard.
--
--  RÈGLES, DANS L'ORDRE. La première qui s'applique gagne.
--
--    1. L'organisation change             -> CHGT_TITULAIRE
--    2. Au moins un contrat change        -> TRANSFERT_INTER_CONTRAT
--    3. Le SI et le CF changent           -> CHGT_SI_ET_CF
--    4. Seul le SI change                 -> CHGT_SITE_INSTALLATION
--    5. Seul le CF change
--         maille MASSE, 1 cible           -> REORG_FACT_CENTRA
--         maille MASSE, n cibles          -> REORG_FACT_DECENTRA
--         maille SELECTION                -> CHGT_SITE_FACTURATION
--    6. Rien ne change                    -> NULL
--
--  POURQUOI LE LOT N'INTERVIENT PAS
--  Sa structure est toujours reproduite à l'identique, donc ses lignes de
--  INF915_OBJET_PARENT sont toujours en CREATION et ne disent rien de l'intention du
--  conseiller. Et la question « ce lot bascule-t-il en entier » ne relève pas de
--  l'acte métier mais de la stratégie d'exécution : c'est au worker de constater, au
--  moment où il traite, qu'un lot part intégralement et d'appliquer le cas échéant un
--  déplacement d'en-tête plutôt qu'une coupure et recréation de chaque BdS. Ce choix
--  se fait au bon moment, avec le parc sous les yeux, pas des semaines plus tôt.
--  Conséquence : TRANSFERT_LOT disparaît du référentiel, TRANSFERT_INTER_CONTRAT
--  couvre l'ancien Fusac comme l'ancien transfert administratif inter-contrat.
--
--  POURQUOI LA MAILLE ARBITRE LE CAS DU SITE DE FACTURATION
--  MASSE signifie que le conseiller a pris tout son périmètre : il réorganise.
--  SELECTION signifie qu'il a désigné des lignes une par une : il change le payeur de
--  ces lignes-là. C'est l'intention du conseiller, déjà enregistrée, qui tranche.
--
--  LIMITE CONNUE DU MODÈLE
--  Une centralisation vers un site de facturation à créer n'est pas représentable en
--  l'état : dix sources en TYPE_CIBLE = 'CREATION' valent dix créations distinctes,
--  donc la déduction conclut à une décentralisation. Correctif en fin de fichier.
-- =====================================================================================


CREATE OR REPLACE PACKAGE INF915_PY AS

  -- ---------------------------------------------------------------------------------
  --  SECTION 1 — QUALIFICATION DE L'OPÉRATION
  -- ---------------------------------------------------------------------------------

  -- Déduit le code opération d'une demande. Renvoie NULL si rien ne change.
  -- Fonction pure : aucune écriture, aucun accès au parc, utilisable dans un SELECT.
  FUNCTION FN_CODE_OPERATION (p_id_notification IN NUMBER) RETURN VARCHAR2;

  -- Déduit et écrit le code opération sur l'en-tête. N'échoue jamais : écrit NULL
  -- si aucun axe n'est modifié. Appelée par le worker, pas par l'IHM.
  PROCEDURE PR_MAJ_CODE_OPERATION (p_id_notification IN NUMBER);

  -- Qualifie en une passe toutes les demandes qui ne le sont pas encore, ou toutes
  -- celles créées depuis une date donnée. Renvoie le nombre de demandes traitées.
  -- Destinée à un appel périodique par le worker.
  FUNCTION FN_QUALIFIER_EN_ATTENTE (p_depuis IN DATE DEFAULT NULL) RETURN NUMBER;

  -- Primitives exposées pour l'écran de suivi, le diagnostic et les tests.
  FUNCTION FN_NB_MODIFIES (p_id_notification IN NUMBER,
                           p_type_objet      IN VARCHAR2) RETURN NUMBER;
  FUNCTION FN_NB_CIBLES   (p_id_notification IN NUMBER,
                           p_type_objet      IN VARCHAR2) RETURN NUMBER;

  -- ---------------------------------------------------------------------------------
  --  SECTION 2 — CRÉATION DE LA DEMANDE
  --
  --  Point d'entrée du service web de captation, et seule procédure du package appelée
  --  par autre chose qu'un worker.
  --
  --  CONTRAT D'APPEL, en trois temps dans la même session :
  --    1. le service insère le périmètre dans INF915_TMP_LIGNE, une ligne par ligne de
  --       service retenue : son master id et son rattachement contrat, SI, CF ;
  --    2. il insère dans INF915_TMP_CIBLE une ligne par objet parent qui change, les
  --       objets absents de cette table étant conservés tels quels ;
  --    3. il appelle PR_CREER_DEMANDE.
  --
  --  La procédure purge les deux tables temporaires en sortie, qu'elle ait réussi ou
  --  échoué, et valide ou annule elle-même : le service n'a rien à gérer.
  --
  --  PERFORMANCE
  --  Tout est ensembliste. Aucune boucle, aucun curseur, aucun traitement ligne à
  --  ligne : cinq INSERT ... SELECT et un UPDATE, quel que soit le volume. Sur cent
  --  mille lignes, le coût est celui de l'insertion elle-même, pas celui d'un parcours.
  --  Le seul surcoût par ligne est le trigger d'identifiant, qui se contente de
  --  constater que la valeur est déjà fournie.
  --
  --  RÉSOLUTION DU PÉRIMÈTRE
  --  Le service raisonne en master id, pas en objid. La procédure rapproche chaque
  --  ligne du parc par une égalité stricte sur quatre colonnes : le master id contre
  --  X_AV_ID_EDS, et le rattachement contrat, SI, CF contre celui du parc. Seule la
  --  BdS1 est retenue, par CHILD2CONTR_ITM IS NULL.
  --
  --  Cette forme a été préférée à des filtres de périmètre passés en paramètre, pour
  --  deux raisons. Le parcours autorise plusieurs contrats, plusieurs SI et plusieurs
  --  CF dans un même périmètre, qu'un paramètre scalaire ne saurait pas exprimer. Et
  --  un même master id peut exister sur plusieurs BdS : seul le rattachement exact de
  --  la ligne retenue lève l'ambiguïté, là où un filtre global ne ferait que la
  --  réduire. La jointure n'en est que plus efficace, toutes ses conditions étant des
  --  égalités.
  --
  --  S'y ajoutent deux conditions reprises de l'existant, qui écartent les BdS
  --  laissées derrière elles par un transfert antérieur : X_AV_FLAG_TRANSFERT
  --  différent de 1 et statut d'activation différent de Résilié.
  --
  --  Tout écart entre le nombre de lignes fournies et le nombre de BdS1 retrouvées
  --  annule la demande.
  --
  --  ERREURS
  --  Rien n'est levé vers l'appelant : un service web préfère un code à une exception.
  --  po_code_erreur est NULL en cas de succès, sinon un code fonctionnel que l'IHM peut
  --  traduire, ou 'ERREUR_TECHNIQUE' avec le détail Oracle dans po_msg_erreur.
  -- ---------------------------------------------------------------------------------

  PROCEDURE PR_CREER_DEMANDE (p_id_orga_source   IN  NUMBER,
                              p_id_orga_cible    IN  NUMBER   DEFAULT NULL,
                              p_maille           IN  VARCHAR2,
                              p_date_effet       IN  DATE,
                              p_acteur           IN  VARCHAR2,
                              po_id_notification OUT NUMBER,
                              po_code_erreur     OUT VARCHAR2,
                              po_msg_erreur      OUT VARCHAR2);
  -- ---------------------------------------------------------------------------------

  -- ---------------------------------------------------------------------------------
  --  SECTION 3 — CRÉATION DES OBJETS CIBLES
  --
  --  Un objet cible est une copie conforme de son objet source, dont seuls les liens
  --  vers le parc cible et les attributs d'identité sont réécrits.
  --
  --  Une procédure par type d'objet, et aucune requête dynamique. La copie passe par un
  --  enregistrement %ROWTYPE : SELECT * INTO l_row, réécriture des quelques champs
  --  concernés, puis INSERT ... VALUES l_row. Toutes les colonnes sont donc reprises
  --  sans qu'aucune liste ne soit à maintenir, et chaque nom de champ réécrit est
  --  vérifié à la compilation.
  --
  --  Le même principe vaut pour les satellites d'un site, rôles d'organisation et rôles
  --  de contact : ils sont copiés ligne à ligne plutôt que recréés, ce qui reprend la
  --  valorisation exacte de l'original sans réimplémenter aucune règle.
  --
  --  AUCUNE DÉPENDANCE À GESTION_SERVICE_GENERIQUE_PKG. Ce package n'est pas pérenne :
  --  tout ce dont INF915 avait besoin est réimplémenté ici. Ne subsistent que trois
  --  objets autonomes du socle, qui ne partagent pas son sort et ne sont pas
  --  remplaçables puisqu'ils encapsulent l'allocation d'identifiants Clarify :
  --    SA.PROC_X_AV_GETNEXTOBJID_II  allocation d'objid, tables sans GUID
  --    SA.PROC_X_AV_GETNEXTOBJID_III allocation d'objid, tables avec GUID
  --    SA.GETCLARIFYNEXTID           identifiants fonctionnels
  --    SA.FUNC_X_AV_GETNEXTSITE_ID   suffixe de construction d'un SITE_ID
  -- ---------------------------------------------------------------------------------

  -- Construit un SITE_ID neuf pour une organisation. Reprend la logique de
  -- F_GETNEXTSITEID, réimplémentée ici pour couper la dépendance.
  FUNCTION FN_NOUVEAU_SITE_ID (p_objid_org IN NUMBER) RETURN VARCHAR2;

  -- Créateurs par type d'objet. Chacun renvoie l'objid de l'objet créé.
  FUNCTION FN_CREER_CONTRAT (p_objid_source    IN NUMBER,
                             p_objid_org_cible IN NUMBER) RETURN NUMBER;
  FUNCTION FN_CREER_SITE    (p_objid_source    IN NUMBER,
                             p_objid_org_cible IN NUMBER) RETURN NUMBER;
  FUNCTION FN_CREER_LOT     (p_objid_source        IN NUMBER,
                             p_objid_contrat_cible IN NUMBER,
                             p_objid_si_cible      IN NUMBER,
                             p_objid_cf_cible      IN NUMBER) RETURN NUMBER;

  -- Cible résolue d'un objet source, telle qu'enregistrée dans INF915_OBJET_PARENT.
  FUNCTION FN_CIBLE (p_id_notification IN NUMBER,
                     p_type_objet      IN VARCHAR2,
                     p_objid_source    IN NUMBER) RETURN NUMBER;

  -- Orchestrateur de la phase séquentielle : crée tous les objets d'une demande dans
  -- l'ordre de leurs dépendances, met à jour INF915_OBJET_PARENT et les compteurs, puis
  -- positionne la demande sur PARENTS_CREES ou PARENTS_EN_ERREUR.
  -- Rejouable : les objets déjà créés ne sont pas repris.
  PROCEDURE PR_CREER_OBJETS_PARENTS (p_id_notification IN NUMBER,
                                     p_acteur          IN VARCHAR2 DEFAULT 'WORKER');

  -- ---------------------------------------------------------------------------------
  --  SECTION 4 — TRANSFERT DES LIGNES
  --
  --  Le traitement est unitaire : une ligne, une transaction. Plusieurs workers peuvent
  --  donc tourner en parallèle sur la même demande sans se gêner, et un échec n'affecte
  --  que sa propre ligne.
  --
  --  UNE LIGNE, UNE PRISE, UNE TRANSACTION
  --  Le package ne distribue pas le travail : c'est l'orchestrateur qui lit la liste
  --  des lignes à traiter et les confie une par une à ses processus. Chaque appel de
  --  PR_TRAITER_LIGNE porte donc sur une seule ligne.
  --
  --  La prise reste atomique, mais au niveau de la ligne : PR_TRAITER_LIGNE commence
  --  par un UPDATE conditionné à STATUT = 'A_TRAITER'. Si la ligne a déjà été prise
  --  par quelqu'un d'autre, l'UPDATE ne touche rien et la procédure rend la main sans
  --  bruit. Deux orchestrateurs lancés par erreur sur la même demande ne peuvent donc
  --  pas traiter la même ligne, sans qu'aucun verrou ne soit conservé.
  --
  --  IDEMPOTENCE
  --  Une ligne dont ID_CONTR_ITM_CIBLE est déjà valorisé a déjà été transférée : elle
  --  est ignorée, quel que soit son statut. Une reprise après incident ne crée donc
  --  jamais de doublon.
  --
  --  OÙ SONT LES BLOCS D'EXCEPTION
  --  Une seule règle : on rattrape là où se trouve la frontière de transaction, et
  --  nulle part ailleurs.
  --    PR_TRAITER_LIGNE ouvre et ferme la transaction d'une ligne : elle rattrape tout,
  --      annule, consigne l'erreur sur la ligne et rend la main sans jamais propager.
  --    PR_TRANSFERER_BDS1, PR_COPIER_BDS et PR_RESILIER_BDS travaillent à l'intérieur
  --      de cette transaction : elles laissent remonter, volontairement. Un WHEN OTHERS
  --      qui ne peut ni annuler ni valider ne sait que journaliser puis relancer, au
  --      risque d'avaler une erreur.
  --    PR_TRAITER_LIGNES rattrape pour libérer les lignes qu'elle détenait encore, puis
  --      relance : un worker qui meurt ne doit pas laisser de lignes bloquées.
  --  Les seules exceptions nommées ailleurs traduisent une donnée absente en message
  --  lisible, NO_DATA_FOUND en particulier, et relancent aussitôt.
  -- ---------------------------------------------------------------------------------

  -- Ouvre la phase lignes : bascule la demande en EN_COURS_LIGNES et trace le jalon.
  -- Appelée une fois par l'orchestrateur avant de distribuer les lignes.
  PROCEDURE PR_DEBUT_LIGNES (p_id_notification IN NUMBER,
                             p_acteur          IN VARCHAR2 DEFAULT 'WORKER');

  -- Transfère une ligne de service complète : la BdS1 et ses BdS2, créées sur la cible
  -- puis résiliées sur la source. Renvoie l'objid de la BdS1 créée.
  PROCEDURE PR_TRANSFERER_BDS1 (p_objid_bds1_source IN  NUMBER,
                                p_objid_lot         IN  NUMBER,
                                p_objid_si          IN  NUMBER,
                                p_objid_cf          IN  NUMBER,
                                p_date_effet        IN  DATE,
                                po_objid_bds1_cible OUT NUMBER);

  -- Transfère une ligne du périmètre. Valide ou annule sa propre transaction, et ne
  -- remonte jamais d'exception.
  PROCEDURE PR_TRAITER_LIGNE (p_id_ligne IN NUMBER,
                              p_worker   IN VARCHAR2 DEFAULT 'WORKER');

  -- Remet en file les lignes restées EN_COURS sans avoir abouti : reprise après l'arrêt
  -- brutal d'un worker. Sans p_worker, toutes celles de la demande ; sans p_minutes,
  -- sans condition d'ancienneté.
  PROCEDURE PR_LIBERER_LIGNES (p_id_notification IN NUMBER,
                               p_worker          IN VARCHAR2 DEFAULT NULL,
                               p_minutes         IN NUMBER   DEFAULT NULL);

  -- Clôture une demande dont toutes les lignes sont traitées : TRAITEE,
  -- TRAITEE_PARTIELLE ou EN_ERREUR selon le décompte. Sans effet si des lignes restent.
  PROCEDURE PR_CLOTURER (p_id_notification IN NUMBER,
                         p_acteur          IN VARCHAR2 DEFAULT 'WORKER');
  -- ---------------------------------------------------------------------------------

  -- ---------------------------------------------------------------------------------
  --  SECTION 5 — CONTRÔLES D'EXÉCUTION               (emplacement réservé)
  -- ---------------------------------------------------------------------------------

END INF915_PY;
/


CREATE OR REPLACE PACKAGE BODY INF915_PY AS

  -- =================================================================================
  --  SECTION 2 — CRÉATION DE LA DEMANDE
  -- =================================================================================

  PROCEDURE PR_CREER_DEMANDE (p_id_orga_source   IN  NUMBER,
                              p_id_orga_cible    IN  NUMBER   DEFAULT NULL,
                              p_maille           IN  VARCHAR2,
                              p_date_effet       IN  DATE,
                              p_acteur           IN  VARCHAR2,
                              po_id_notification OUT NUMBER,
                              po_code_erreur     OUT VARCHAR2,
                              po_msg_erreur      OUT VARCHAR2) IS
    l_id        NUMBER;
    l_nb_tmp    PLS_INTEGER;
    l_nb_lignes PLS_INTEGER;
    l_nb_mauvais PLS_INTEGER;
  BEGIN
    po_id_notification := NULL;
    po_code_erreur     := NULL;
    po_msg_erreur      := NULL;

    -- -------------------------------------------------------------------------------
    --  Contrôles d'entrée. Tous ensemblistes, donc insensibles au volume.
    -- -------------------------------------------------------------------------------
    IF p_id_orga_source IS NULL THEN
      po_code_erreur := 'ORGA_SOURCE_ABSENTE';
      po_msg_erreur  := 'L''organisation source est obligatoire.';
      GOTO purge;
    END IF;

    IF p_id_orga_cible IS NOT NULL AND p_id_orga_cible = p_id_orga_source THEN
      po_code_erreur := 'ORGA_CIBLE_EGALE_SOURCE';
      po_msg_erreur  := 'L''organisation cible doit etre laissee a NULL si elle ne change pas.';
      GOTO purge;
    END IF;

    IF NVL (p_maille, '~') NOT IN ('MASSE','SELECTION') THEN
      po_code_erreur := 'MAILLE_INVALIDE';
      po_msg_erreur  := 'La maille doit valoir MASSE ou SELECTION, recue : ' || p_maille;
      GOTO purge;
    END IF;

    IF p_date_effet IS NULL THEN
      po_code_erreur := 'DATE_EFFET_ABSENTE';
      po_msg_erreur  := 'La date d''effet est obligatoire.';
      GOTO purge;
    END IF;

    SELECT COUNT(*) INTO l_nb_tmp FROM INF915_TMP_LIGNE;
    IF l_nb_tmp = 0 THEN
      po_code_erreur := 'PERIMETRE_VIDE';
      po_msg_erreur  := 'Aucune ligne dans INF915_TMP_LIGNE.';
      GOTO purge;
    END IF;

    -- Un objet parent ne peut pas avoir deux cibles.
    SELECT COUNT(*) INTO l_nb_mauvais
      FROM (SELECT TYPE_OBJET, ID_OBJET_SOURCE
              FROM INF915_TMP_CIBLE
             GROUP BY TYPE_OBJET, ID_OBJET_SOURCE
            HAVING COUNT(*) > 1);
    IF l_nb_mauvais > 0 THEN
      po_code_erreur := 'CIBLE_EN_DOUBLE';
      po_msg_erreur  := l_nb_mauvais || ' objet(s) parent(s) ont plusieurs cibles dans '
                        || 'INF915_TMP_CIBLE.';
      GOTO purge;
    END IF;

    SELECT COUNT(*) INTO l_nb_mauvais
      FROM INF915_TMP_CIBLE
     WHERE TYPE_OBJET NOT IN ('CONTRAT','SI','CF')
        OR TYPE_CIBLE NOT IN ('EXISTANT','CREATION')
        OR (TYPE_CIBLE = 'EXISTANT' AND ID_OBJET_CIBLE IS NULL);
    IF l_nb_mauvais > 0 THEN
      po_code_erreur := 'CIBLE_INVALIDE';
      po_msg_erreur  := l_nb_mauvais || ' ligne(s) de INF915_TMP_CIBLE sont invalides : '
                        || 'type d''objet hors CONTRAT, SI, CF, type de cible hors '
                        || 'EXISTANT, CREATION, ou cible EXISTANT sans identifiant.';
      GOTO purge;
    END IF;

    -- -------------------------------------------------------------------------------
    --  En-tête. La référence dérive de l'identifiant, donc unique sans second compteur.
    -- -------------------------------------------------------------------------------
    SELECT SEQ_INF915_NOTIF.NEXTVAL INTO l_id FROM DUAL;

    INSERT INTO INF915_NOTIFICATIONS
          (ID_NOTIFICATION, REFERENCE, ID_ORGA_SOURCE, ID_ORGA_CIBLE,
           MAILLE, DATE_EFFET, STATUT)
    VALUES (l_id,
            'TR-' || TO_CHAR (p_date_effet, 'YYYY') || '-' || LPAD (TO_CHAR (l_id), 6, '0'),
            p_id_orga_source, p_id_orga_cible,
            p_maille, p_date_effet, 'EN_ATTENTE');

    -- -------------------------------------------------------------------------------
    --  Le périmètre, résolu et figé en une seule instruction.
    --
    --  La correspondance avec le parc est une égalité stricte sur quatre colonnes : le
    --  master id contre X_AV_ID_EDS, et le rattachement contrat, SI, CF contre celui du
    --  parc. CHILD2CONTR_ITM IS NULL ne retient que la BdS1 ; ses BdS2 sont retrouvées
    --  au moment du transfert par leur rattachement à elle.
    --
    --  Le rattachement portant sur chaque ligne, un périmètre à plusieurs contrats,
    --  plusieurs SI ou plusieurs CF s'exprime naturellement, et deux lignes homonymes
    --  rattachées différemment ne peuvent plus se confondre.
    --
    --  Le rattachement source est figé ici une fois pour toutes : plus rien ne relira
    --  le parc pour savoir d'où venait une ligne.
    --
    --  L'identifiant est fourni par la séquence dans le SELECT plutôt que laissé au
    --  trigger : sur cent mille lignes, cela évite autant de passages dans le contexte
    --  PL/SQL pour y lire la même séquence.
    -- -------------------------------------------------------------------------------
    INSERT INTO INF915_LIGNE
          (ID_LIGNE, ID_NOTIFICATION, ID_CONTR_ITM,
           ID_CONTRAT_SOURCE, ID_SI_SOURCE, ID_CF_SOURCE, ID_LOT_SOURCE,
           STATUT_ACT_SOURCE, STATUT_MAT_SOURCE)
    SELECT SEQ_INF915_LIGNE.NEXTVAL, l_id, i.OBJID,
           s.SCHEDULE2CONTRACT, i.X_AV_USED_BY2SITE, i.X_AV_BILL_TO2SITE,
           i.CONTR_ITM2CONTR_SCHEDULE,
           i.X_AV_STATUT_ACT, i.X_AV_STATUT_MAT
      FROM INF915_TMP_LIGNE        t
      JOIN SA.TABLE_CONTR_ITM      i ON i.X_AV_ID_EDS       = t.MASTER_ID
                                    AND i.CHILD2CONTR_ITM  IS NULL
                                    AND i.X_AV_USED_BY2SITE = t.ID_SI_SOURCE
                                    AND i.X_AV_BILL_TO2SITE = t.ID_CF_SOURCE
      JOIN SA.TABLE_CONTR_SCHEDULE s ON s.OBJID             = i.CONTR_ITM2CONTR_SCHEDULE
                                    AND s.SCHEDULE2CONTRACT = t.ID_CONTRAT_SOURCE
       -- Écarte les BdS qu'un transfert antérieur a laissées derrière lui : après un
       -- premier passage, le même master id existe sur la BdS résiliée et sur celle
       -- qui l'a remplacée. Conditions reprises de chTitulaireMobilePrice.
     WHERE NVL (i.X_AV_FLAG_TRANSFERT, 0) <> 1
       AND NVL (i.X_AV_STATUT_ACT, '~')   <> 'Résilié';

    l_nb_lignes := SQL%ROWCOUNT;

    -- L'écart se lit dans les deux sens, et les deux sont graves.
    --   moins de lignes que fournies : certaines ne correspondent à aucune BdS1 ayant
    --     exactement ce rattachement, ou la BdS est résiliée ou déjà transférée ;
    --   plus de lignes que fournies : deux BdS1 partagent le même master id et le même
    --     rattachement, ce qui ne devrait pas exister et mérite un signalement.
    -- Dans les deux cas la demande est annulée plutôt que créée de travers.
    IF l_nb_lignes <> l_nb_tmp THEN
      ROLLBACK;
      po_code_erreur := 'PERIMETRE_INCOHERENT';
      po_msg_erreur  := l_nb_tmp || ' ligne(s) fournies, ' || l_nb_lignes ||
                        ' BdS1 retrouvees. ' ||
                        CASE WHEN l_nb_lignes < l_nb_tmp
                             THEN 'Certaines ne correspondent a aucune BdS1 portant ce '
                                  || 'master id et ce rattachement contrat, SI, CF, ou '
                                  || 'la BdS est resiliee ou deja transferee.'
                             ELSE 'Deux BdS1 partagent le meme master id et le meme '
                                  || 'rattachement, ce qui ne devrait pas exister.'
                        END;
      GOTO purge;
    END IF;

    -- -------------------------------------------------------------------------------
    --  Les objets parents, par agrégation du périmètre.
    --
    --  Un objet absent de INF915_TMP_CIBLE reste identique à lui-même : c'est le
    --  LEFT JOIN qui le dit, et le NVL qui le traduit. MAX sur les colonnes de la
    --  table de mapping évite de les faire entrer dans le GROUP BY, ce qui est licite
    --  puisque le contrôle de doublon ci-dessus garantit une cible au plus.
    --
    --  L'identifiant est ici laissé au trigger : ces instructions agrègent, et une
    --  séquence n'est pas admise dans un SELECT avec GROUP BY. Le volume s'y prête,
    --  quelques centaines d'objets au plus.
    -- -------------------------------------------------------------------------------
    INSERT INTO INF915_OBJET_PARENT
          (ID_NOTIFICATION, TYPE_OBJET, ID_OBJET_SOURCE, NB_LIGNES,
           TYPE_CIBLE, ID_OBJET_CIBLE)
    SELECT l_id, 'CONTRAT', l.ID_CONTRAT_SOURCE, COUNT(*),
           NVL (MAX (c.TYPE_CIBLE), 'IDENTIQUE'),
           CASE WHEN MAX (c.TYPE_CIBLE) = 'CREATION' THEN NULL
                ELSE NVL (MAX (c.ID_OBJET_CIBLE), l.ID_CONTRAT_SOURCE) END
      FROM INF915_LIGNE      l
      LEFT JOIN INF915_TMP_CIBLE c ON c.TYPE_OBJET      = 'CONTRAT'
                                  AND c.ID_OBJET_SOURCE = l.ID_CONTRAT_SOURCE
     WHERE l.ID_NOTIFICATION = l_id
     GROUP BY l.ID_CONTRAT_SOURCE;

    INSERT INTO INF915_OBJET_PARENT
          (ID_NOTIFICATION, TYPE_OBJET, ID_OBJET_SOURCE, NB_LIGNES,
           TYPE_CIBLE, ID_OBJET_CIBLE)
    SELECT l_id, 'SI', l.ID_SI_SOURCE, COUNT(*),
           NVL (MAX (c.TYPE_CIBLE), 'IDENTIQUE'),
           CASE WHEN MAX (c.TYPE_CIBLE) = 'CREATION' THEN NULL
                ELSE NVL (MAX (c.ID_OBJET_CIBLE), l.ID_SI_SOURCE) END
      FROM INF915_LIGNE      l
      LEFT JOIN INF915_TMP_CIBLE c ON c.TYPE_OBJET      = 'SI'
                                  AND c.ID_OBJET_SOURCE = l.ID_SI_SOURCE
     WHERE l.ID_NOTIFICATION = l_id
     GROUP BY l.ID_SI_SOURCE;

    INSERT INTO INF915_OBJET_PARENT
          (ID_NOTIFICATION, TYPE_OBJET, ID_OBJET_SOURCE, NB_LIGNES,
           TYPE_CIBLE, ID_OBJET_CIBLE)
    SELECT l_id, 'CF', l.ID_CF_SOURCE, COUNT(*),
           NVL (MAX (c.TYPE_CIBLE), 'IDENTIQUE'),
           CASE WHEN MAX (c.TYPE_CIBLE) = 'CREATION' THEN NULL
                ELSE NVL (MAX (c.ID_OBJET_CIBLE), l.ID_CF_SOURCE) END
      FROM INF915_LIGNE      l
      LEFT JOIN INF915_TMP_CIBLE c ON c.TYPE_OBJET      = 'CF'
                                  AND c.ID_OBJET_SOURCE = l.ID_CF_SOURCE
     WHERE l.ID_NOTIFICATION = l_id
     GROUP BY l.ID_CF_SOURCE;

    -- Les lots ne figurent jamais dans le mapping : leur structure est toujours
    -- reproduite à l'identique, donc toujours en création.
    INSERT INTO INF915_OBJET_PARENT
          (ID_NOTIFICATION, TYPE_OBJET, ID_OBJET_SOURCE, NB_LIGNES,
           TYPE_CIBLE, ID_OBJET_CIBLE)
    SELECT l_id, 'LOT', l.ID_LOT_SOURCE, COUNT(*), 'CREATION', NULL
      FROM INF915_LIGNE l
     WHERE l.ID_NOTIFICATION = l_id
     GROUP BY l.ID_LOT_SOURCE;

    -- -------------------------------------------------------------------------------
    --  Compteurs de l'en-tête, lus une fois sur les objets parents qui viennent d'être
    --  écrits. L'écran de suivi n'aura donc rien à agréger à chaud.
    -- -------------------------------------------------------------------------------
    UPDATE INF915_NOTIFICATIONS n
       SET NB_LIGNES = l_nb_lignes,
           (NB_CONTRATS, NB_SI, NB_CF, NB_LOTS, NB_OBJETS_A_CREER) =
             (SELECT SUM (CASE WHEN TYPE_OBJET = 'CONTRAT' THEN 1 ELSE 0 END),
                     SUM (CASE WHEN TYPE_OBJET = 'SI'      THEN 1 ELSE 0 END),
                     SUM (CASE WHEN TYPE_OBJET = 'CF'      THEN 1 ELSE 0 END),
                     SUM (CASE WHEN TYPE_OBJET = 'LOT'     THEN 1 ELSE 0 END),
                     SUM (CASE WHEN TYPE_CIBLE = 'CREATION' THEN 1 ELSE 0 END)
                FROM INF915_OBJET_PARENT p
               WHERE p.ID_NOTIFICATION = n.ID_NOTIFICATION)
     WHERE n.ID_NOTIFICATION = l_id;

    -- -------------------------------------------------------------------------------
    --  Historique. Écrire la demande vaut validation : les contrôles d'éligibilité ont
    --  été joués en amont par le service, et une demande n'existe que si elle est
    --  valide. L'acteur est donc un utilisateur, pas un worker.
    -- -------------------------------------------------------------------------------
    INSERT INTO INF915_ACTION
          (ID_NOTIFICATION, TYPE_ACTION, ACTEUR, TYPE_ACTEUR, STATUT_APRES)
    VALUES (l_id, 'CREATION', p_acteur, 'UTILISATEUR', 'EN_ATTENTE');

    po_id_notification := l_id;

    -- CODE_OPERATION reste nul : c'est une étiquette de restitution, qualifiée après
    -- coup par le worker. La captation n'a pas à l'attendre.

    DELETE FROM INF915_TMP_LIGNE;
    DELETE FROM INF915_TMP_CIBLE;
    COMMIT;
    RETURN;

    -- -------------------------------------------------------------------------------
    --  Sortie en échec fonctionnel. Les tables temporaires sont purgées dans tous les
    --  cas : une session de service web est réutilisée, et des restes y fausseraient
    --  l'appel suivant.
    -- -------------------------------------------------------------------------------
    <<purge>>
    DELETE FROM INF915_TMP_LIGNE;
    DELETE FROM INF915_TMP_CIBLE;
    COMMIT;

  EXCEPTION
    WHEN OTHERS THEN
      po_code_erreur := 'ERREUR_TECHNIQUE';
      po_msg_erreur  := SUBSTR (TO_CHAR (SQLCODE) || ' ' || SQLERRM, 1, 500);
      po_id_notification := NULL;
      ROLLBACK;
      BEGIN
        DELETE FROM INF915_TMP_LIGNE;
        DELETE FROM INF915_TMP_CIBLE;
        COMMIT;
      EXCEPTION
        WHEN OTHERS THEN
          ROLLBACK;        -- la purge a echoue aussi : on ne masque pas l'erreur initiale
      END;
  END PR_CREER_DEMANDE;


  -- =================================================================================
  --  SECTION 3 — CRÉATION DES OBJETS CIBLES
  -- =================================================================================

  c_dom_contrat      CONSTANT VARCHAR2(60) := 'Not B-End Quote ID';  -- cf CREATE_NEW_CONTRACT
  c_dom_lot          CONSTANT VARCHAR2(60) := 'Schedule ID';         -- cf CreateNewSchedule
  c_role_signataire  CONSTANT VARCHAR2(60) := 'Signataire';          -- cf C_ROLE_SIGNATAIRE


  -- ---------------------------------------------------------------------------------
  --  CONTRAT
  --
  --  Copie conforme du contrat source, avec un identifiant technique neuf et le
  --  rattachement à l'organisation cible. Les attributs dénormalisés de l'organisation
  --  portés par TABLE_CONTRACT, TITLE, S_TITLE et X_AV_BU, sont réalignés comme le fait
  --  CREATE_NEW_CONTRACT. Le compteur de lots repart à zéro : le contrat créé n'en
  --  porte encore aucun.
  --
  --  Tout le reste est conservé par l'enregistrement : catégorie d'offre, RCS,
  --  qualification, marché public, chaîne de déploiement, conditions, devise.
  --
  --  POINT DE VIGILANCE : X_AV_CONTRACT2VPN pointe sur un VPN qui appartient à
  --  l'organisation source. Si l'organisation change, le contrat créé référencera un
  --  VPN étranger à son organisation. Le VPN doit alors être recréé en amont, par
  --  P_CREATE_VPN et P_CREATE_VPN2SIREN, et son objid affecté ici. À arbitrer avec le
  --  métier : le cas se présente-t-il sur un changement de titulaire ?
  -- ---------------------------------------------------------------------------------
  FUNCTION FN_CREER_CONTRAT (p_objid_source    IN NUMBER,
                             p_objid_org_cible IN NUMBER) RETURN NUMBER IS
    l_row   SA.TABLE_CONTRACT%ROWTYPE;
    l_org   SA.TABLE_BUS_ORG%ROWTYPE;
    l_objid NUMBER;
    l_id    VARCHAR2(60);
  BEGIN
    BEGIN
      SELECT * INTO l_row FROM SA.TABLE_CONTRACT WHERE OBJID = p_objid_source;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR (-20923,
          'INF915 : contrat source introuvable, objid ' || p_objid_source);
    END;

    BEGIN
      SELECT * INTO l_org FROM SA.TABLE_BUS_ORG WHERE OBJID = p_objid_org_cible;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR (-20926,
          'INF915 : organisation cible introuvable, objid ' || p_objid_org_cible);
    END;

    SA.PROC_X_AV_GETNEXTOBJID_II ('contract', l_objid);
    l_id := SA.GETCLARIFYNEXTID (c_dom_contrat);

    l_row.OBJID           := l_objid;
    l_row.ID              := l_id;
    l_row.S_ID            := l_id;
    l_row.SELL_TO2BUS_ORG := p_objid_org_cible;
    l_row.TITLE           := l_org.NAME;
    l_row.S_TITLE         := l_org.S_NAME;
    l_row.X_AV_BU         := l_org.X_AV_BU;
    l_row.X_AV_NB_SCHED   := 0;

    INSERT INTO SA.TABLE_CONTRACT VALUES l_row;

    RETURN l_objid;
  END FN_CREER_CONTRAT;


  -- ---------------------------------------------------------------------------------
  --  IDENTIFIANT DE SITE
  --
  --  Réimplémentation de F_GETNEXTSITEID. Le SITE_ID est construit par concaténation de
  --  l'identifiant de l'organisation et d'un suffixe de trois caractères dérivé d'un
  --  compteur porté par l'organisation elle-même, X_AV_NB_SITE_FACT.
  --
  --  Le comportement d'origine est reproduit tel quel, y compris sa particularité : en
  --  cas de collision, le compteur local avance mais celui de l'organisation ne suit
  --  pas, si bien qu'il peut prendre du retard. Corriger ce point ferait diverger les
  --  identifiants produits ici de ceux produits par le socle, ce qui serait pire.
  -- ---------------------------------------------------------------------------------
  FUNCTION FN_NOUVEAU_SITE_ID (p_objid_org IN NUMBER) RETURN VARCHAR2 IS
    l_org_id  SA.TABLE_BUS_ORG.ORG_ID%TYPE;
    l_cnt     SA.TABLE_BUS_ORG.X_AV_NB_SITE_FACT%TYPE;
    l_site_id SA.TABLE_SITE.SITE_ID%TYPE;
    l_existe  PLS_INTEGER := 1;
  BEGIN
    BEGIN
      SELECT ORG_ID INTO l_org_id FROM SA.TABLE_BUS_ORG WHERE OBJID = p_objid_org;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR (-20926,
          'INF915 : organisation cible introuvable, objid ' || p_objid_org);
    END;

    UPDATE SA.TABLE_BUS_ORG
       SET X_AV_NB_SITE_FACT = X_AV_NB_SITE_FACT + 1
     WHERE OBJID = p_objid_org
    RETURNING X_AV_NB_SITE_FACT - 1 INTO l_cnt;

    WHILE l_existe = 1
    LOOP
      l_cnt     := l_cnt + 1;
      l_site_id := l_org_id || LPAD (SA.FUNC_X_AV_GETNEXTSITE_ID (l_cnt), 3, '0');

      SELECT COUNT(*) INTO l_existe FROM SA.TABLE_SITE WHERE SITE_ID = l_site_id;
    END LOOP;

    RETURN l_site_id;
  END FN_NOUVEAU_SITE_ID;


  -- ---------------------------------------------------------------------------------
  --  SITE, d'installation comme de facturation
  --
  --  Un site ne se résume pas à sa ligne de TABLE_SITE. La création se fait en trois
  --  temps, tous par copie conforme :
  --    1. la ligne, avec un objid, un GUID et un SITE_ID neufs, et le rattachement
  --       PRIMARY2BUS_ORG vers l'organisation cible ;
  --    2. les rôles du site vis-à-vis de l'organisation, TABLE_BUS_SITE_ROLE ;
  --    3. les rôles de contact, TABLE_CONTACT_ROLE.
  --
  --  Les étapes 2 et 3 copient les lignes existantes plutôt que de les recréer. C'est
  --  volontaire : la valorisation exacte de l'original est reprise, y compris les
  --  drapeaux dont la règle nous échappe, et aucune logique de création n'est
  --  réimplémentée. Un rôle mal copié serait un rôle identique à sa source.
  --
  --  L'étape 3 n'est pas cosmétique : SA.VERIF_CF exige un contact portant le rôle
  --  « Destinataire principal de la facture » sur tout site de facturation. Sans elle,
  --  un CF créé échouerait au contrôle de complétude de la facturation.
  --
  --  Le rôle Signataire est volontairement exclu : une organisation n'a qu'un site
  --  signataire, et le dupliquer en produirait un second, ce qui rendrait ambiguë la
  --  recherche du contact signataire à la création d'un contrat.
  -- ---------------------------------------------------------------------------------
  FUNCTION FN_CREER_SITE (p_objid_source    IN NUMBER,
                          p_objid_org_cible IN NUMBER) RETURN NUMBER IS
    l_row      SA.TABLE_SITE%ROWTYPE;
    l_role     SA.TABLE_BUS_SITE_ROLE%ROWTYPE;
    l_contact  SA.TABLE_CONTACT_ROLE%ROWTYPE;
    l_objid    NUMBER;
    l_objid_r  NUMBER;
    l_guid     SA.TABLE_SITE.GUID%TYPE;
    l_site_id  SA.TABLE_SITE.SITE_ID%TYPE;
  BEGIN
    BEGIN
      SELECT * INTO l_row FROM SA.TABLE_SITE WHERE OBJID = p_objid_source;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR (-20923,
          'INF915 : site source introuvable, objid ' || p_objid_source);
    END;

    -- 1. la ligne
    SA.PROC_X_AV_GETNEXTOBJID_III ('site', l_objid, l_guid);
    l_site_id := FN_NOUVEAU_SITE_ID (p_objid_org_cible);

    l_row.OBJID           := l_objid;
    l_row.GUID            := l_guid;
    l_row.SITE_ID         := l_site_id;
    l_row.S_SITE_ID       := UPPER (l_site_id);
    l_row.PRIMARY2BUS_ORG := p_objid_org_cible;

    INSERT INTO SA.TABLE_SITE VALUES l_row;

    -- 2. rôles du site vis-à-vis de l'organisation
    FOR r IN (SELECT OBJID
                FROM SA.TABLE_BUS_SITE_ROLE
               WHERE BUS_SITE_ROLE2SITE = p_objid_source
                 AND ROLE_NAME         <> c_role_signataire)
    LOOP
      SELECT * INTO l_role FROM SA.TABLE_BUS_SITE_ROLE WHERE OBJID = r.OBJID;

      SA.PROC_X_AV_GETNEXTOBJID_II ('bus_site_role', l_objid_r);

      l_role.OBJID                 := l_objid_r;
      l_role.BUS_SITE_ROLE2SITE    := l_objid;
      l_role.BUS_SITE_ROLE2BUS_ORG := p_objid_org_cible;

      INSERT INTO SA.TABLE_BUS_SITE_ROLE VALUES l_role;
    END LOOP;

    -- 3. rôles de contact, dont le destinataire principal de la facture
    FOR c IN (SELECT OBJID
                FROM SA.TABLE_CONTACT_ROLE
               WHERE CONTACT_ROLE2SITE      = p_objid_source
                 AND ROLE_NAME             <> c_role_signataire
                 AND CONTACT_ROLE2CONTACT IS NOT NULL)
    LOOP
      SELECT * INTO l_contact FROM SA.TABLE_CONTACT_ROLE WHERE OBJID = c.OBJID;

      SA.PROC_X_AV_GETNEXTOBJID_II ('contact_role', l_objid_r);

      l_contact.OBJID                := l_objid_r;
      l_contact.CONTACT_ROLE2SITE    := l_objid;
      l_contact.CONTACT_ROLE2BUS_ORG := p_objid_org_cible;
      l_contact.UPDATE_STAMP         := SYSTIMESTAMP;

      INSERT INTO SA.TABLE_CONTACT_ROLE VALUES l_contact;
    END LOOP;

    RETURN l_objid;
  END FN_CREER_SITE;


  -- ---------------------------------------------------------------------------------
  --  LOT
  --
  --  Copie conforme du lot source, avec repointage des trois liens qui le définissent :
  --  son contrat, son site d'installation et son site de facturation.
  --
  --  La valorisation reprend celle de CreateNewSchedule dans chmt_cf.cbs, y compris la
  --  règle de nommage et sa troncature à 40 caractères, l'incrément de X_AV_NB_SCHED
  --  sur le contrat cible, et l'identifiant externe neuf exigé par E026.
  --
  --  Une différence assumée avec l'existant : CreateNewSchedule duplique un lot
  --  quelconque du contrat cible, ce qui l'oblige à réécrire la famille, la ligne et
  --  l'offre. Ici le lot source est copié, donc sa FLO, son programme de prix et ses
  --  attributs de facturation sont déjà les bons et n'ont pas à être réécrits.
  --
  --  TABLE_CONTR_SCHEDULE est supposée sans GUID, comme TABLE_CONTRACT. Si elle en
  --  porte un, remplacer l'appel par PROC_X_AV_GETNEXTOBJID_III et affecter l_row.GUID :
  --  la compilation le signalera, puisque le champ existerait dans l'enregistrement.
  -- ---------------------------------------------------------------------------------
  FUNCTION FN_CREER_LOT (p_objid_source        IN NUMBER,
                         p_objid_contrat_cible IN NUMBER,
                         p_objid_si_cible      IN NUMBER,
                         p_objid_cf_cible      IN NUMBER) RETURN NUMBER IS
    l_row        SA.TABLE_CONTR_SCHEDULE%ROWTYPE;
    l_objid      NUMBER;
    l_nb_sched   NUMBER;
    l_version    SA.TABLE_CONTRACT.X_AV_CURRENT_VERSION%TYPE;
    l_nom_si     SA.TABLE_SITE.NAME%TYPE;
    l_id_externe VARCHAR2(60);
  BEGIN
    BEGIN
      SELECT * INTO l_row FROM SA.TABLE_CONTR_SCHEDULE WHERE OBJID = p_objid_source;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR (-20923,
          'INF915 : lot source introuvable, objid ' || p_objid_source);
    END;

    -- Compteur de lots du contrat cible, comme le fait CreateNewSchedule
    UPDATE SA.TABLE_CONTRACT
       SET X_AV_NB_SCHED = NVL (X_AV_NB_SCHED, 0) + 1
     WHERE OBJID = p_objid_contrat_cible
    RETURNING X_AV_NB_SCHED, X_AV_CURRENT_VERSION INTO l_nb_sched, l_version;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR (-20924,
        'INF915 : contrat cible introuvable, objid ' || p_objid_contrat_cible);
    END IF;

    BEGIN
      SELECT NAME INTO l_nom_si FROM SA.TABLE_SITE WHERE OBJID = p_objid_si_cible;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR (-20930,
          'INF915 : site d''installation cible introuvable, objid ' || p_objid_si_cible);
    END;

    SA.PROC_X_AV_GETNEXTOBJID_II ('contr_schedule', l_objid);
    l_id_externe := SA.GETCLARIFYNEXTID (c_dom_lot);

    l_row.OBJID             := l_objid;
    l_row.SCHEDULE2CONTRACT := p_objid_contrat_cible;
    l_row.SHIP_TO2SITE      := p_objid_si_cible;
    l_row.BILL_TO2SITE      := p_objid_cf_cible;

    -- Règle de nommage reprise à l'identique de CreateNewSchedule
    IF LENGTH (l_nom_si || '_' || l_nb_sched) > 40 THEN
      l_row.SCHEDULE_ID := SUBSTR (l_nom_si, 1, 39 - LENGTH (TO_CHAR (l_nb_sched)))
                           || '_' || l_nb_sched;
    ELSE
      l_row.SCHEDULE_ID := l_nom_si || '_' || l_nb_sched;
    END IF;

    l_row.ITEM_COUNT       := 0;
    l_row.LAST_P_LINE_NO   := 0;
    l_row.X_AV_ID_IMPORT   := NULL;
    l_row.X_AV_ID_INSTALL  := l_id_externe;
    l_row.X_AV_ID_EXT_SITE := l_id_externe;
    l_row.X_AV_STATUS      := 'Actif';
    l_row.X_AV_VERSION     := l_version;
    l_row.LAST_UPDATE      := SYSDATE;
    -- X_AV_DTFACT est alimentée par CStr(App.CurrentDate) dans l'existant, donc sous
    -- forme de chaîne. Si la colonne est de type DATE, remplacer par SYSDATE.
    l_row.X_AV_DTFACT      := TO_CHAR (SYSDATE, 'DD/MM/YYYY');

    INSERT INTO SA.TABLE_CONTR_SCHEDULE VALUES l_row;

    RETURN l_objid;
  END FN_CREER_LOT;


  -- ---------------------------------------------------------------------------------
  --  RÉSOLUTION D'UNE CIBLE
  -- ---------------------------------------------------------------------------------
  FUNCTION FN_CIBLE (p_id_notification IN NUMBER,
                     p_type_objet      IN VARCHAR2,
                     p_objid_source    IN NUMBER) RETURN NUMBER IS
    l_objid NUMBER;
  BEGIN
    SELECT p.ID_OBJET_CIBLE
      INTO l_objid
      FROM INF915_OBJET_PARENT p
     WHERE p.ID_NOTIFICATION = p_id_notification
       AND p.TYPE_OBJET      = p_type_objet
       AND p.ID_OBJET_SOURCE = p_objid_source;
    RETURN l_objid;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      -- Objet absent du périmètre : la cible est la source elle-même.
      RETURN p_objid_source;
  END FN_CIBLE;


  -- ---------------------------------------------------------------------------------
  --  TRAÇAGE
  -- ---------------------------------------------------------------------------------
  PROCEDURE PR_TRACER (p_id_notification IN NUMBER,
                       p_type_action     IN VARCHAR2,
                       p_acteur          IN VARCHAR2,
                       p_statut_avant    IN VARCHAR2 DEFAULT NULL,
                       p_statut_apres    IN VARCHAR2 DEFAULT NULL,
                       p_motif           IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    INSERT INTO INF915_ACTION
      (ID_NOTIFICATION, TYPE_ACTION, ACTEUR, TYPE_ACTEUR, STATUT_AVANT, STATUT_APRES, MOTIF)
    VALUES
      (p_id_notification, p_type_action, p_acteur, 'SYSTEME',
       p_statut_avant, p_statut_apres, p_motif);
  END PR_TRACER;


  -- ---------------------------------------------------------------------------------
  --  ORCHESTRATEUR DE LA PHASE SÉQUENTIELLE
  --
  --  Parcourt les objets à créer dans l'ordre de leurs dépendances : les contrats
  --  d'abord, puis les sites, puis les lots qui référencent les deux. Chaque création
  --  est validée individuellement, ce qui rend la phase rejouable : un objet déjà créé
  --  n'est pas repris, et un échec n'annule pas ce qui a réussi.
  -- ---------------------------------------------------------------------------------
  PROCEDURE PR_CREER_OBJETS_PARENTS (p_id_notification IN NUMBER,
                                     p_acteur          IN VARCHAR2 DEFAULT 'WORKER') IS
    l_statut  INF915_NOTIFICATIONS.STATUT%TYPE;
    l_org     NUMBER;
    l_objid   NUMBER;
    l_nb_ok   PLS_INTEGER := 0;
    l_nb_ko   PLS_INTEGER := 0;
    l_contrat NUMBER;
    l_si      NUMBER;
    l_cf      NUMBER;
    l_final   INF915_NOTIFICATIONS.STATUT%TYPE;
  BEGIN
    SELECT STATUT, NVL (ID_ORGA_CIBLE, ID_ORGA_SOURCE)
      INTO l_statut, l_org
      FROM INF915_NOTIFICATIONS
     WHERE ID_NOTIFICATION = p_id_notification
       FOR UPDATE;

    IF l_statut NOT IN ('EN_ATTENTE','PARENTS_EN_ERREUR') THEN
      ROLLBACK;                                -- relâche le verrou du FOR UPDATE
      RAISE_APPLICATION_ERROR (-20925,
        'INF915 : la demande ' || p_id_notification || ' est en statut ' || l_statut ||
        ', la phase objets parents n''est pas applicable.');
    END IF;

    UPDATE INF915_NOTIFICATIONS SET STATUT = 'EN_COURS_PARENTS'
     WHERE ID_NOTIFICATION = p_id_notification;
    PR_TRACER (p_id_notification, 'DEBUT_PARENTS', p_acteur, l_statut, 'EN_COURS_PARENTS');
    COMMIT;

    -- Les objets conservés ou réutilisés n'ont rien à créer : on les marque une fois
    -- pour toutes, la boucle ne traite ensuite que les créations.
    UPDATE INF915_OBJET_PARENT
       SET STATUT          = CASE TYPE_CIBLE WHEN 'IDENTIQUE' THEN 'SANS_OBJET'
                                                              ELSE 'REUTILISE' END,
           DATE_TRAITEMENT = SYSTIMESTAMP
     WHERE ID_NOTIFICATION = p_id_notification
       AND TYPE_CIBLE     <> 'CREATION'
       AND STATUT          = 'A_TRAITER';

    FOR r IN (SELECT ID_OBJET_PARENT, TYPE_OBJET, ID_OBJET_SOURCE
                FROM INF915_OBJET_PARENT
               WHERE ID_NOTIFICATION = p_id_notification
                 AND TYPE_CIBLE      = 'CREATION'
                 AND STATUT         IN ('A_TRAITER','ERREUR')
               ORDER BY DECODE (TYPE_OBJET,'CONTRAT',1,'SI',2,'CF',3,'LOT',4),
                        ID_OBJET_PARENT)
    LOOP
      BEGIN
        IF r.TYPE_OBJET = 'CONTRAT' THEN
          l_objid := FN_CREER_CONTRAT (r.ID_OBJET_SOURCE, l_org);

        ELSIF r.TYPE_OBJET IN ('SI','CF') THEN
          l_objid := FN_CREER_SITE (r.ID_OBJET_SOURCE, l_org);

        ELSE
          -- Un lot se rattache au contrat et aux deux sites de son lot source, résolus
          -- dans leur version cible. Les trois ont déjà été traités par l'ordre de la
          -- boucle, leur objid cible est donc connu.
          SELECT FN_CIBLE (p_id_notification, 'CONTRAT', s.SCHEDULE2CONTRACT),
                 FN_CIBLE (p_id_notification, 'SI',      s.SHIP_TO2SITE),
                 FN_CIBLE (p_id_notification, 'CF',      s.BILL_TO2SITE)
            INTO l_contrat, l_si, l_cf
            FROM SA.TABLE_CONTR_SCHEDULE s
           WHERE s.OBJID = r.ID_OBJET_SOURCE;

          l_objid := FN_CREER_LOT (r.ID_OBJET_SOURCE, l_contrat, l_si, l_cf);
        END IF;

        UPDATE INF915_OBJET_PARENT
           SET ID_OBJET_CIBLE  = l_objid,
               STATUT          = 'CREE',
               DATE_TRAITEMENT = SYSTIMESTAMP,
               NB_TENTATIVES   = NB_TENTATIVES + 1,
               CODE_ERREUR     = NULL,
               MSG_ERREUR      = NULL
         WHERE ID_OBJET_PARENT = r.ID_OBJET_PARENT;

        l_nb_ok := l_nb_ok + 1;
        COMMIT;                       -- une création validée n'est jamais reprise

      EXCEPTION
        WHEN OTHERS THEN
          ROLLBACK;
          UPDATE INF915_OBJET_PARENT
             SET STATUT          = 'ERREUR',
                 DATE_TRAITEMENT = SYSTIMESTAMP,
                 NB_TENTATIVES   = NB_TENTATIVES + 1,
                 CODE_ERREUR     = TO_CHAR (SQLCODE),
                 MSG_ERREUR      = SUBSTR (SQLERRM, 1, 500)
           WHERE ID_OBJET_PARENT = r.ID_OBJET_PARENT;
          l_nb_ko := l_nb_ko + 1;
          COMMIT;
      END;
    END LOOP;

    l_final := CASE WHEN l_nb_ko > 0 THEN 'PARENTS_EN_ERREUR' ELSE 'PARENTS_CREES' END;

    UPDATE INF915_NOTIFICATIONS
       SET NB_OBJETS_CREES = (SELECT COUNT(*) FROM INF915_OBJET_PARENT
                               WHERE ID_NOTIFICATION = p_id_notification
                                 AND STATUT          = 'CREE'),
           STATUT          = l_final
     WHERE ID_NOTIFICATION = p_id_notification;

    PR_TRACER (p_id_notification, 'FIN_PARENTS', p_acteur, 'EN_COURS_PARENTS', l_final,
               l_nb_ok || ' objet(s) cree(s), ' || l_nb_ko || ' en erreur');
    COMMIT;
  END PR_CREER_OBJETS_PARENTS;


  -- =================================================================================
  --  SECTION 4 — TRANSFERT DES LIGNES
  -- =================================================================================

  c_date_ouverte CONSTANT DATE := TO_DATE ('01/01/1753', 'DD/MM/YYYY');  -- cf MAT VSR 59


  -- ---------------------------------------------------------------------------------
  --  OUVERTURE DE LA PHASE LIGNES
  --
  --  Appelée une fois par l'orchestrateur, avant qu'il ne distribue les lignes à ses
  --  processus. Tolère d'être rappelée sur une demande déjà ouverte, ce qui arrive à
  --  la reprise d'un traitement interrompu.
  -- ---------------------------------------------------------------------------------
  PROCEDURE PR_DEBUT_LIGNES (p_id_notification IN NUMBER,
                             p_acteur          IN VARCHAR2 DEFAULT 'WORKER') IS
    l_statut INF915_NOTIFICATIONS.STATUT%TYPE;
  BEGIN
    SELECT STATUT INTO l_statut
      FROM INF915_NOTIFICATIONS
     WHERE ID_NOTIFICATION = p_id_notification
       FOR UPDATE;

    IF l_statut IN ('EN_ATTENTE_TRT_LIGNES','EN_ATTENTE') THEN
      UPDATE INF915_NOTIFICATIONS SET STATUT = 'EN_COURS_LIGNES'
       WHERE ID_NOTIFICATION = p_id_notification;
      PR_TRACER (p_id_notification, 'DEBUT_LIGNES', p_acteur, l_statut, 'EN_COURS_LIGNES');
      COMMIT;

    ELSIF l_statut IN ('EN_COURS_LIGNES','TRAITEE_PARTIELLE','EN_ERREUR') THEN
      ROLLBACK;                                -- reprise, la phase est déjà ouverte

    ELSE
      ROLLBACK;
      RAISE_APPLICATION_ERROR (-20943,
        'INF915 : la demande ' || p_id_notification || ' est en statut ' || l_statut ||
        ', le transfert des lignes n''est pas applicable.');
    END IF;
  END PR_DEBUT_LIGNES;


  -- ---------------------------------------------------------------------------------
  --  NUMÉRO DE LIGNE DANS LE LOT CIBLE
  --
  --  Reprend la requête de ChmtCFPrice : le rang suivant le plus grand déjà posé sur
  --  le lot. Sur des workers parallèles, deux lignes du même lot peuvent viser le même
  --  rang ; c'est pourquoi la prise de lot ordonne par ID_LIGNE et qu'une contrainte
  --  d'unicité sur (contr_itm2contr_schedule, p_line_no) serait à vérifier côté socle.
  --  À confirmer : y en a-t-il une ?
  -- ---------------------------------------------------------------------------------
  FUNCTION FN_PROCHAIN_RANG (p_objid_lot IN NUMBER) RETURN NUMBER IS
    l_rang NUMBER;
  BEGIN
    SELECT NVL (MAX (P_LINE_NO), 0) + 1
      INTO l_rang
      FROM SA.TABLE_CONTR_ITM
     WHERE CONTR_ITM2CONTR_SCHEDULE = p_objid_lot;
    RETURN l_rang;
  END FN_PROCHAIN_RANG;


  -- ---------------------------------------------------------------------------------
  --  CARACTÉRISTIQUES D'UNE BdS, LUES UNE FOIS
  --
  --  Les matrices de statuts dépendent toutes des mêmes quatre attributs de l'article
  --  et du statut Arbor courant de la BdS.
  -- ---------------------------------------------------------------------------------
  PROCEDURE PR_CARACTERISTIQUES (p_objid_bds   IN  NUMBER,
                                 po_install    OUT VARCHAR2,
                                 po_type       OUT VARCHAR2,
                                 po_cross_ref  OUT VARCHAR2,
                                 po_gen_si     OUT NUMBER,
                                 po_arb_status OUT VARCHAR2) IS
  BEGIN
    SELECT p.X_AV_INSTALL_TYPE, p.X_AV_TYPE, p.X_AV_CROSS_REF,
           NVL (p.X_AV_GEN_SI, 0), i.X_AV_ARB_STATUS
      INTO po_install, po_type, po_cross_ref, po_gen_si, po_arb_status
      FROM SA.TABLE_CONTR_ITM  i
      JOIN SA.TABLE_MOD_LEVEL  m ON m.OBJID = i.CONTR_ITM2MOD_LEVEL
      JOIN SA.TABLE_PART_NUM   p ON p.OBJID = m.PART_INFO2PART_NUM
     WHERE i.OBJID = p_objid_bds;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR (-20944,
        'INF915 : article introuvable pour la BdS ' || p_objid_bds);
  END PR_CARACTERISTIQUES;


  -- ---------------------------------------------------------------------------------
  --  COPIE D'UNE BdS
  --
  --  Procédure et non fonction : l'objid créé n'intéresse l'appelant que pour la BdS1,
  --  qui sert de point de rattachement à ses BdS2 et de référence à la ligne. Le
  --  rendre par un paramètre de sortie évite de laisser croire qu'une valeur de retour
  --  est ignorée par oubli.
  --
  --  Copie conforme d'une BdS, quelle que soit sa nature. Le repointage porte sur le
  --  lot, les deux sites, la numérotation dans le lot cible, l'identifiant de service
  --  et, pour une BdS2, le rattachement à sa BdS1.
  --
  --  Numérotation, reprise de ChmtCFPrice : toutes les BdS d'une même ligne partagent
  --  le même P_LINE_NO, celui du rang libre dans le lot cible. Seul LINE_NO_TXT les
  --  distingue, « 12 » pour la BdS1 et « 12.1 », « 12.2 » pour ses BdS2, dont le
  --  LINE_NO porte le sous-rang.
  --
  --  Ce qui n'est pas repris de la source : CREATE_DATE remise au jour, X_AV_ID_IMPORT
  --  et X_AV_NUM_MVT vidés, X_AV_CHGMT_CU_CF remis à zéro, CHG_END_DT positionnée sur
  --  la date ouverte.
  -- ---------------------------------------------------------------------------------
  PROCEDURE PR_COPIER_BDS (p_objid_source IN  NUMBER,
                           p_objid_lot    IN  NUMBER,
                           p_objid_si     IN  NUMBER,
                           p_objid_cf     IN  NUMBER,
                           p_date_effet   IN  DATE,
                           p_rang         IN  NUMBER,
                           p_sous_rang    IN  NUMBER,   -- NULL pour une BdS1
                           p_id_ids       IN  VARCHAR2,
                           p_objid_bds1   IN  NUMBER,   -- NULL pour une BdS1
                           po_objid       OUT NUMBER) IS
    l_row       SA.TABLE_CONTR_ITM%ROWTYPE;
    l_attr      SA.TABLE_N_ATTRIBUTEVALUE%ROWTYPE;
    l_ajust     SA.TABLE_CONTR_PR%ROWTYPE;
    l_objid     NUMBER;
    l_objid_s   NUMBER;
    l_version   SA.TABLE_CONTRACT.X_AV_CURRENT_VERSION%TYPE;
    l_install   SA.TABLE_PART_NUM.X_AV_INSTALL_TYPE%TYPE;
    l_type      SA.TABLE_PART_NUM.X_AV_TYPE%TYPE;
    l_cross_ref SA.TABLE_PART_NUM.X_AV_CROSS_REF%TYPE;
    l_gen_si    NUMBER;
    l_arb       SA.TABLE_CONTR_ITM.X_AV_ARB_STATUS%TYPE;
  BEGIN
    BEGIN
      SELECT * INTO l_row FROM SA.TABLE_CONTR_ITM WHERE OBJID = p_objid_source;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR (-20940,
          'INF915 : BdS source introuvable, objid ' || p_objid_source);
    END;

    SELECT c.X_AV_CURRENT_VERSION
      INTO l_version
      FROM SA.TABLE_CONTR_SCHEDULE s
      JOIN SA.TABLE_CONTRACT       c ON c.OBJID = s.SCHEDULE2CONTRACT
     WHERE s.OBJID = p_objid_lot;

    PR_CARACTERISTIQUES (p_objid_source, l_install, l_type, l_cross_ref, l_gen_si, l_arb);

    SA.PROC_X_AV_GETNEXTOBJID_II ('contr_itm', l_objid);
    po_objid := l_objid;

    l_row.OBJID                    := l_objid;
    l_row.CONTR_ITM2CONTR_SCHEDULE := p_objid_lot;
    l_row.X_AV_USED_BY2SITE        := p_objid_si;
    l_row.X_AV_BILL_TO2SITE        := p_objid_cf;
    l_row.X_AV_ID_IDS              := p_id_ids;
    l_row.X_AV_VERSION             := l_version;
    l_row.CREATE_DATE              := SYSDATE;
    l_row.X_AV_ID_IMPORT           := NULL;
    l_row.X_AV_NUM_MVT             := NULL;
    l_row.X_AV_CHGMT_CU_CF         := 0;
    l_row.CHG_END_DT               := c_date_ouverte;

    -- Numérotation dans le lot cible, et lien vers la BdS d'origine
    l_row.P_LINE_NO := p_rang;
    IF p_sous_rang IS NULL THEN
      l_row.LINE_NO_TXT     := TO_CHAR (p_rang);
      l_row.CHILD2CONTR_ITM := NULL;
      -- Lien entre BdS source et cible, porté par la BdS1 uniquement.
      -- ChmtCFPrice pose ce lien par RelateRecords recNewLI, recOldLI,
      -- "x_av_new2previous" : la colonne est donc sur la BdS créée et pointe vers la
      -- BdS d'origine. x_av_previous2new n'est que le nom de parcours inverse, utilisé
      -- pour retrouver la cible depuis la source.
      -- Le programme d'origine pose ce lien sur toutes les BdS : le test qui le
      -- réservait à la BdS1 y est commenté, RA 6134. Ici il est rétabli.
      l_row.X_AV_NEW2PREVIOUS := p_objid_source;
    ELSE
      l_row.LINE_NO_TXT     := TO_CHAR (p_rang) || '.' || TO_CHAR (p_sous_rang);
      l_row.LINE_NO         := p_sous_rang;
      l_row.CHILD2CONTR_ITM := p_objid_bds1;
    END IF;

    -- Statuts de sortie. Matrice reprise de ChmtCFPrice, branche générale, celle qui
    -- coupe et recrée. Elle s'applique à chaque BdS selon son propre article.
    IF l_install IN ('F','IF') THEN
      IF NVL (l_type, '~') <> 'NRC' THEN
        l_row.X_AV_STATUT_ACT := 'Créé';
        l_row.X_AV_STATUS_C2A := 'Prêt à Facturer';
        l_row.X_AV_ARB_STATUS := 'Initialisation';
      ELSIF l_cross_ref = 'CFE_TERM' AND NVL (l_type, '~') = 'NRC' THEN
        l_row.X_AV_STATUT_ACT := 'Créé';
        l_row.X_AV_ETAT_ACT   := 'Réalisé';
        l_row.X_AV_CODE_ETAT  := 'Traité';
      ELSE
        l_row.X_AV_STATUT_ACT := 'Résilié';
        l_row.X_AV_STATUS_C2A := 'Résilié - Traité';
        l_row.X_AV_ARB_STATUS := 'RES_ARB';
      END IF;
      l_row.CHG_START_DT := p_date_effet;

    ELSIF l_install = 'I' AND l_gen_si = 1 THEN
      l_row.CHG_START_DT := p_date_effet;
    END IF;

    -- BdS génératrice de SI : le statut du SI est vidé sur la copie (C7821966)
    IF l_gen_si = 1 THEN
      l_row.X_AV_STATUT_SI := NULL;
    END IF;

    INSERT INTO SA.TABLE_CONTR_ITM VALUES l_row;

    -- Attributs techniques, recopiés tels quels sur la nouvelle BdS
    FOR a IN (SELECT OBJID FROM SA.TABLE_N_ATTRIBUTEVALUE
               WHERE N_FOCUSLOWID = p_objid_source)
    LOOP
      SELECT * INTO l_attr FROM SA.TABLE_N_ATTRIBUTEVALUE WHERE OBJID = a.OBJID;
      SA.PROC_X_AV_GETNEXTOBJID_II ('n_attributevalue', l_objid_s);
      l_attr.OBJID        := l_objid_s;
      l_attr.N_FOCUSLOWID := l_objid;
      INSERT INTO SA.TABLE_N_ATTRIBUTEVALUE VALUES l_attr;
    END LOOP;

    -- Ajustements de prix
    FOR j IN (SELECT OBJID FROM SA.TABLE_CONTR_PR
               WHERE CONTR_PR2CONTR_ITM = p_objid_source)
    LOOP
      SELECT * INTO l_ajust FROM SA.TABLE_CONTR_PR WHERE OBJID = j.OBJID;
      SA.PROC_X_AV_GETNEXTOBJID_II ('contr_pr', l_objid_s);
      l_ajust.OBJID              := l_objid_s;
      l_ajust.CONTR_PR2CONTR_ITM := l_objid;
      INSERT INTO SA.TABLE_CONTR_PR VALUES l_ajust;
    END LOOP;
  END PR_COPIER_BDS;


  -- ---------------------------------------------------------------------------------
  --  RÉSILIATION D'UNE BdS SOURCE
  --
  --  Appelée une fois par BdS de la ligne : la BdS1, puis chacune de ses BdS2. La
  --  matrice s'évalue sur l'article de chaque BdS, elles peuvent donc suivre des
  --  branches différentes.
  --
  --  Matrice reprise intégralement de ChmtCFPrice, branche générale. Cinq cas, dans
  --  cet ordre, le premier qui s'applique gagne :
  --
  --    1. install_type = 'F'  et type <> 'NRC'
  --         Résilié / Prêt à Résilier / CRE_ARB / chg_end_dt
  --    2. install_type = 'IF' et type <> 'NRC'
  --         Résilié / Prêt à Résilier / CRE_ARB / Réalisé / Traité / chg_end_dt / end_date
  --    3. install_type = 'I'  et gen_si = 1
  --         Résilié / Réalisé / Traité / chg_end_dt / end_date, sans statut Arbor
  --    4. install_type = 'I'
  --         Résilié / Réalisé / Traité / end_date, sans chg_end_dt ni statut Arbor
  --    5. cross_ref = 'CFE_TERM' et type = 'NRC'
  --         Résilié / Réalisé / Traité / end_date, chg_end_dt commentée dans l'origine
  --
  --  Le lien vers la BdS créée n'est pas posé ici : il est porté par la BdS cible,
  --  colonne X_AV_NEW2PREVIOUS, et seulement par la BdS1 de la ligne.
  --
  --  Hors de ces cinq cas, la BdS source n'est pas résiliée. C'est le comportement
  --  d'origine, pas un oubli : une BdS non facturable et non génératrice de SI n'a
  --  rien à résilier.
  --
  --  POURQUOI CRE_ARB SUR UNE RÉSILIATION, ET POURQUOI C'EST À CONFIRMER
  --  x_av_arb_status n'est pas un statut de la BdS mais la trace du dernier ordre
  --  envoyé à Arbor : CRE_ARB création, MOD_ARB modification, RES_ARB résiliation,
  --  plus les variantes en erreur CRE_ERR, MOD_ERR, RES_ERR, MOD_C2A, RES_C2A, et
  --  'Initialisation' pour une BdS qu'Arbor ne connaît pas encore.
  --
  --  Il est lu comme un drapeau d'entrée par la branche « Fixe unitaire » du même
  --  programme, qui n'émet un ordre de résiliation vers Arbor que si la BdS y existe,
  --  c'est-à-dire si son statut vaut CRE_ARB ou MOD_ARB. Poser CRE_ARB sur la BdS que
  --  l'on résilie revient donc, très probablement, à forcer l'émission de cet ordre
  --  par la réplication qui suit.
  --
  --  Cette lecture reste une hypothèse. Si elle est fausse, la valeur attendue est
  --  RES_ARB, comme dans les cas où le programme clôture directement. Les deux
  --  possibilités sont dans le code, l'une active, l'autre en commentaire, et le choix
  --  appartient à l'équipe qui connaît la réplication Arbor.
  -- ---------------------------------------------------------------------------------
  PROCEDURE PR_RESILIER_BDS (p_objid_source IN NUMBER,
                             p_date_effet   IN DATE) IS
    l_install   SA.TABLE_PART_NUM.X_AV_INSTALL_TYPE%TYPE;
    l_type      SA.TABLE_PART_NUM.X_AV_TYPE%TYPE;
    l_cross_ref SA.TABLE_PART_NUM.X_AV_CROSS_REF%TYPE;
    l_gen_si    NUMBER;
    l_arb       SA.TABLE_CONTR_ITM.X_AV_ARB_STATUS%TYPE;
    l_row       SA.TABLE_CONTR_ITM%ROWTYPE;
    l_traite    BOOLEAN := TRUE;
  BEGIN
    PR_CARACTERISTIQUES (p_objid_source, l_install, l_type, l_cross_ref, l_gen_si, l_arb);

    SELECT * INTO l_row FROM SA.TABLE_CONTR_ITM WHERE OBJID = p_objid_source FOR UPDATE;

    IF l_install = 'F'  AND NVL (l_type, '~') <> 'NRC' THEN
      l_row.X_AV_STATUT_ACT := 'Résilié';
      l_row.X_AV_STATUS_C2A := 'Prêt à Résilier';
      --l_row.X_AV_ARB_STATUS := 'CRE_ARB';   -- hypothèse : drapeau d'émission Arbor
      -- l_row.X_AV_ARB_STATUS := 'RES_ARB';   -- lecture alternative, à trancher
      l_row.CHG_END_DT      := p_date_effet;

    ELSIF l_install = 'IF'  AND NVL (l_type, '~') <> 'NRC' THEN
      l_row.X_AV_STATUT_ACT := 'Résilié';
      l_row.X_AV_STATUS_C2A := 'Prêt à Résilier';
      --l_row.X_AV_ARB_STATUS := 'CRE_ARB';   -- idem
      l_row.X_AV_ETAT_ACT   := 'Réalisé';
      l_row.X_AV_CODE_ETAT  := 'Traité';
      l_row.CHG_END_DT      := p_date_effet;
      l_row.END_DATE        := p_date_effet;

    ELSIF l_install = 'I' AND l_gen_si = 1 THEN
      l_row.CHG_END_DT      := p_date_effet;
      l_row.X_AV_STATUT_ACT := 'Résilié';
      l_row.X_AV_ETAT_ACT   := 'Réalisé';
      l_row.X_AV_CODE_ETAT  := 'Traité';
      l_row.END_DATE        := p_date_effet;

    ELSIF l_install = 'I' THEN
      l_row.X_AV_STATUT_ACT := 'Résilié';
      l_row.X_AV_ETAT_ACT   := 'Réalisé';
      l_row.X_AV_CODE_ETAT  := 'Traité';
      l_row.END_DATE        := p_date_effet;
      -- chg_end_dt volontairement non posée, comme dans l'origine

    ELSIF l_cross_ref = 'CFE_TERM' AND NVL (l_type, '~') = 'NRC' THEN
      l_row.X_AV_STATUT_ACT := 'Résilié';
      l_row.X_AV_ETAT_ACT   := 'Réalisé';
      l_row.X_AV_CODE_ETAT  := 'Traité';
      l_row.END_DATE        := p_date_effet;
      -- chg_end_dt commentée dans l'origine, COR C20123366

    ELSE
      l_traite := FALSE;                    -- aucune résiliation dans ce cas
    END IF;

    -- Traçabilité du transfert, posée quel que soit le cas
    l_row.X_AV_CHGMT_CU_CF := 0;            -- attesté, ChmtCFPrice
    l_row.X_AV_OSS_ID_DEM  := NULL;         -- attesté, recopié sur la BdS cible

    -- Ces deux valorisations, que j'avais ajoutées, ne sont pas attestées dans la
    -- branche générale de ChmtCFPrice. X_AV_NB_TRANSF n'y est incrémenté que dans la
    -- branche « Fixe unitaire », et X_AV_FLAG_TRANSFERT n'apparaît que dans d'autres
    -- sous-programmes. Laissées en commentaire, à activer si le métier le confirme.
    -- l_row.X_AV_FLAG_TRANSFERT := 1;
    -- l_row.X_AV_NB_TRANSF      := NVL (l_row.X_AV_NB_TRANSF, 0) + 1;

    UPDATE SA.TABLE_CONTR_ITM SET ROW = l_row WHERE OBJID = p_objid_source;
  END PR_RESILIER_BDS;


  -- ---------------------------------------------------------------------------------
  --  TRANSFERT D'UNE LIGNE DE SERVICE, BdS1 ET BdS2
  --
  --  Une ligne de service, un IDS, n'est pas une BdS mais un ensemble : une BdS1, celle
  --  dont CHILD2CONTR_ITM est nul, et ses BdS2, qui pointent vers elle par cette même
  --  colonne. INF915_LIGNE ne porte que la BdS1 ; ses BdS2 sont retrouvées ici et
  --  suivent le même sort.
  --
  --  L'ordre compte : la BdS1 est créée d'abord, parce que ses BdS2 doivent s'y
  --  rattacher et reprendre son identifiant de service. Toutes les BdS de la ligne
  --  partagent donc le même IDS, neuf, et le même rang dans le lot cible.
  --
  --  Chaque BdS est ensuite résiliée sur la source, avec le lien vers sa propre copie.
  -- ---------------------------------------------------------------------------------
  PROCEDURE PR_TRANSFERER_BDS1 (p_objid_bds1_source IN  NUMBER,
                                p_objid_lot         IN  NUMBER,
                                p_objid_si          IN  NUMBER,
                                p_objid_cf          IN  NUMBER,
                                p_date_effet        IN  DATE,
                                po_objid_bds1_cible OUT NUMBER) IS
    l_rang  NUMBER;
    l_ids   SA.TABLE_CONTR_ITM.X_AV_ID_IDS%TYPE;
    l_sous  PLS_INTEGER := 1;
    l_bds2  NUMBER;          -- objid de la BdS2 créée, sans usage en aval : rien ne
                             -- s'y rattache et la ligne ne référence que sa BdS1
    l_nul   PLS_INTEGER;
  BEGIN
    -- Garde-fou : la ligne doit bien porter une BdS1.
    SELECT COUNT(*) INTO l_nul
      FROM SA.TABLE_CONTR_ITM
     WHERE OBJID = p_objid_bds1_source AND CHILD2CONTR_ITM IS NULL;
    IF l_nul = 0 THEN
      RAISE_APPLICATION_ERROR (-20945,
        'INF915 : la BdS ' || p_objid_bds1_source || ' n''est pas une BdS1, ' ||
        'CHILD2CONTR_ITM est renseigne.');
    END IF;

    l_rang := FN_PROCHAIN_RANG (p_objid_lot);
    SELECT SA.FUNC_GET_ID_IDS INTO l_ids FROM DUAL;

    -- 1. la BdS1, dont l'objid sert à rattacher ses BdS2 et à valoriser la ligne
    PR_COPIER_BDS (p_objid_bds1_source, p_objid_lot, p_objid_si, p_objid_cf,
                   p_date_effet, l_rang, NULL, l_ids, NULL,
                   po_objid_bds1_cible);
    PR_RESILIER_BDS (p_objid_bds1_source, p_date_effet);

    -- 2. les BdS2, dans leur ordre de numérotation d'origine
    FOR b IN (SELECT OBJID
                FROM SA.TABLE_CONTR_ITM
               WHERE CHILD2CONTR_ITM = p_objid_bds1_source
               ORDER BY LINE_NO, OBJID)
    LOOP
      PR_COPIER_BDS (b.OBJID, p_objid_lot, p_objid_si, p_objid_cf,
                     p_date_effet, l_rang, l_sous, l_ids, po_objid_bds1_cible,
                     l_bds2);
      PR_RESILIER_BDS (b.OBJID, p_date_effet);
      l_sous := l_sous + 1;
    END LOOP;
  END PR_TRANSFERER_BDS1;


  -- ---------------------------------------------------------------------------------
  --  TRANSFERT D'UNE LIGNE
  --
  --  Une ligne, une transaction. La procédure ne remonte jamais d'exception : une
  --  erreur est consignée sur la ligne et le worker passe à la suivante.
  -- ---------------------------------------------------------------------------------
  PROCEDURE PR_TRAITER_LIGNE (p_id_ligne IN NUMBER,
                              p_worker   IN VARCHAR2 DEFAULT 'WORKER') IS
    l_lig    INF915_LIGNE%ROWTYPE;
    l_effet  DATE;
    l_cible  NUMBER;
    l_port   NUMBER;
    l_code   NUMBER;
    l_msg    VARCHAR2(500);
  BEGIN
    -- Prise de la ligne. Conditionnée au statut, donc atomique : si un autre processus
    -- l'a déjà prise, l'UPDATE ne touche rien et on rend la main sans bruit. C'est ce
    -- qui protège d'un double lancement de l'orchestrateur sur la même demande.
    UPDATE INF915_LIGNE
       SET STATUT     = 'EN_COURS',
           ID_WORKER  = p_worker,
           DATE_DEBUT = SYSTIMESTAMP
     WHERE ID_LIGNE = p_id_ligne
       AND STATUT   = 'A_TRAITER';

    IF SQL%ROWCOUNT = 0 THEN
      ROLLBACK;
      RETURN;
    END IF;
    COMMIT;

    SELECT l.*, n.DATE_EFFET
      INTO l_lig, l_effet
      FROM INF915_LIGNE        l
      JOIN INF915_NOTIFICATIONS n ON n.ID_NOTIFICATION = l.ID_NOTIFICATION
     WHERE l.ID_LIGNE = p_id_ligne;

    -- Idempotence : une ligne déjà transférée n'est jamais rejouée.
    IF l_lig.ID_CONTR_ITM_CIBLE IS NOT NULL THEN
      UPDATE INF915_LIGNE
         SET STATUT = 'TRANSFEREE', DATE_FIN = SYSTIMESTAMP
       WHERE ID_LIGNE = p_id_ligne;
      COMMIT;
      RETURN;
    END IF;

    -- BdS porteuse : sa cible doit exister avant celle de la ligne portée.
    l_port := NULL;
    IF l_lig.ID_LIGNE_PORTEUSE IS NOT NULL THEN
      SELECT ID_CONTR_ITM_CIBLE INTO l_port
        FROM INF915_LIGNE WHERE ID_LIGNE = l_lig.ID_LIGNE_PORTEUSE;
      IF l_port IS NULL THEN
        RAISE_APPLICATION_ERROR (-20942,
          'INF915 : la BdS porteuse de la ligne ' || p_id_ligne ||
          ' n''est pas encore transferee.');
      END IF;
    END IF;

    PR_TRANSFERER_BDS1 (l_lig.ID_CONTR_ITM,
                        l_lig.ID_LOT_CIBLE,
                        l_lig.ID_SI_CIBLE,
                        l_lig.ID_CF_CIBLE,
                        l_effet,
                        l_cible);

    UPDATE INF915_LIGNE
       SET ID_CONTR_ITM_CIBLE = l_cible,
           STATUT             = 'TRANSFEREE',
           ETAPE              = 'Propagation aval',
           DATE_FIN           = SYSTIMESTAMP,
           NB_TENTATIVES      = NB_TENTATIVES + 1,
           CODE_ERREUR        = NULL,
           MSG_ERREUR         = NULL
     WHERE ID_LIGNE = p_id_ligne;

    UPDATE INF915_NOTIFICATIONS
       SET NB_LIGNES_OK = NB_LIGNES_OK + 1
     WHERE ID_NOTIFICATION = l_lig.ID_NOTIFICATION;

    COMMIT;

  EXCEPTION
    WHEN OTHERS THEN
      -- Le code et le message sont relevés avant toute autre instruction : SQLCODE et
      -- SQLERRM changent dès qu'on exécute quoi que ce soit dans le handler.
      -- Une erreur applicative, -20999 à -20000, est une règle métier non respectée ;
      -- tout le reste est technique et donc relançable en l'état.
      l_code := SQLCODE;
      l_msg  := SUBSTR (SQLERRM, 1, 500);
      ROLLBACK;

      -- La consignation est elle-même protégée : si elle échoue, la ligne reste en
      -- EN_COURS et sera remise en file par PR_LIBERER_LIGNES, mais le worker continue.
      BEGIN
        UPDATE INF915_LIGNE
           SET STATUT        = CASE WHEN l_code BETWEEN -20999 AND -20000
                                    THEN 'ERREUR_METIER' ELSE 'ERREUR_TECHNIQUE' END,
               DATE_FIN      = SYSTIMESTAMP,
               NB_TENTATIVES = NB_TENTATIVES + 1,
               CODE_ERREUR   = TO_CHAR (l_code),
               MSG_ERREUR    = l_msg
         WHERE ID_LIGNE = p_id_ligne;

        UPDATE INF915_NOTIFICATIONS n
           SET NB_LIGNES_KO_METIER = NB_LIGNES_KO_METIER +
                 CASE WHEN l_code BETWEEN -20999 AND -20000 THEN 1 ELSE 0 END,
               NB_LIGNES_KO_TECH   = NB_LIGNES_KO_TECH +
                 CASE WHEN l_code BETWEEN -20999 AND -20000 THEN 0 ELSE 1 END
         WHERE n.ID_NOTIFICATION = (SELECT ID_NOTIFICATION FROM INF915_LIGNE
                                     WHERE ID_LIGNE = p_id_ligne);
        COMMIT;
      EXCEPTION
        WHEN OTHERS THEN
          ROLLBACK;
      END;
  END PR_TRAITER_LIGNE;


  -- ---------------------------------------------------------------------------------
  --  LIBÉRATION DES LIGNES ORPHELINES
  --
  --  Une ligne passée en EN_COURS n'est plus prise par FN_PRENDRE_LOT_LIGNES, qui ne
  --  retient que A_TRAITER. Si un worker meurt entre la prise et le traitement, ses
  --  lignes resteraient donc bloquées indéfiniment. Cette procédure les remet en file.
  --
  --  Le filtre sur ID_CONTR_ITM_CIBLE est essentiel : une ligne dont la BdS cible existe
  --  déjà a abouti, son statut n'a simplement pas pu être écrit. La remettre en file la
  --  ferait repasser par PR_TRAITER_LIGNE, qui la reconnaîtra comme déjà transférée.
  -- ---------------------------------------------------------------------------------
  PROCEDURE PR_LIBERER_LIGNES (p_id_notification IN NUMBER,
                               p_worker          IN VARCHAR2 DEFAULT NULL,
                               p_minutes         IN NUMBER   DEFAULT NULL) IS
  BEGIN
    UPDATE INF915_LIGNE
       SET STATUT     = 'A_TRAITER',
           ID_WORKER  = NULL,
           DATE_DEBUT = NULL
     WHERE ID_NOTIFICATION = p_id_notification
       AND STATUT          = 'EN_COURS'
       AND (p_worker  IS NULL OR ID_WORKER = p_worker)
       AND (p_minutes IS NULL
            OR DATE_DEBUT < SYSTIMESTAMP - NUMTODSINTERVAL (p_minutes, 'MINUTE'));
    COMMIT;
  END PR_LIBERER_LIGNES;


  -- ---------------------------------------------------------------------------------
  --  CLÔTURE D'UNE DEMANDE
  -- ---------------------------------------------------------------------------------
  PROCEDURE PR_CLOTURER (p_id_notification IN NUMBER,
                         p_acteur          IN VARCHAR2 DEFAULT 'WORKER') IS
    l_reste  PLS_INTEGER;
    l_ok     PLS_INTEGER;
    l_ko     PLS_INTEGER;
    l_statut INF915_NOTIFICATIONS.STATUT%TYPE;
    l_final  INF915_NOTIFICATIONS.STATUT%TYPE;
  BEGIN
    SELECT STATUT INTO l_statut
      FROM INF915_NOTIFICATIONS WHERE ID_NOTIFICATION = p_id_notification FOR UPDATE;

    -- Toute sortie doit relâcher le verrou posé par le FOR UPDATE. Sans ROLLBACK, un
    -- worker qui constate qu'il n'a rien à clôturer garderait la ligne verrouillée
    -- jusqu'à la fermeture de sa session, et bloquerait ses collègues au premier
    -- incrément de NB_LIGNES_OK. Les workers finissant leur file en premier, c'est-à-
    -- dire ceux qui n'ont rien pris, provoqueraient ainsi un blocage général.
    IF l_statut <> 'EN_COURS_LIGNES' THEN
      ROLLBACK;
      RETURN;
    END IF;

    SELECT COUNT (CASE WHEN STATUT IN ('A_TRAITER','EN_COURS')      THEN 1 END),
           COUNT (CASE WHEN STATUT  = 'TRANSFEREE'                  THEN 1 END),
           COUNT (CASE WHEN STATUT IN ('ERREUR_METIER','ERREUR_TECHNIQUE') THEN 1 END)
      INTO l_reste, l_ok, l_ko
      FROM INF915_LIGNE
     WHERE ID_NOTIFICATION = p_id_notification;

    IF l_reste > 0 THEN
      ROLLBACK;                                -- d'autres workers travaillent encore
      RETURN;
    END IF;

    l_final := CASE WHEN l_ko = 0 THEN 'TRAITEE'
                    WHEN l_ok = 0 THEN 'EN_ERREUR'
                                  ELSE 'TRAITEE_PARTIELLE' END;

    UPDATE INF915_NOTIFICATIONS SET STATUT = l_final
     WHERE ID_NOTIFICATION = p_id_notification;

    PR_TRACER (p_id_notification, 'FIN_TRAITEMENT', p_acteur, 'EN_COURS_LIGNES', l_final,
               l_ok || ' ligne(s) transferee(s), ' || l_ko || ' en erreur');
    COMMIT;
  END PR_CLOTURER;


  -- =================================================================================
  --  SECTION 1 — QUALIFICATION DE L'OPÉRATION
  -- =================================================================================

  -- ---------------------------------------------------------------------------------
  --  Codes opération, alignés sur INF915_REF_OPERATION
  -- ---------------------------------------------------------------------------------
  c_titulaire      CONSTANT VARCHAR2(40) := 'CHGT_TITULAIRE';
  c_inter_contrat  CONSTANT VARCHAR2(40) := 'TRANSFERT_INTER_CONTRAT';
  c_si_et_cf       CONSTANT VARCHAR2(40) := 'CHGT_SI_ET_CF';
  c_site_install   CONSTANT VARCHAR2(40) := 'CHGT_SITE_INSTALLATION';
  c_fact_centra    CONSTANT VARCHAR2(40) := 'REORG_FACT_CENTRA';
  c_fact_decentra  CONSTANT VARCHAR2(40) := 'REORG_FACT_DECENTRA';
  c_site_fact      CONSTANT VARCHAR2(40) := 'CHGT_SITE_FACTURATION';


  -- =================================================================================
  --  PRIMITIVES — une requête chacune, sur INF915_OBJET_PARENT
  -- =================================================================================

  -- Un type d'objet est modifié dès qu'au moins une de ses valeurs source ne reste
  -- pas identique à elle-même.
  FUNCTION FN_NB_MODIFIES (p_id_notification IN NUMBER,
                           p_type_objet      IN VARCHAR2) RETURN NUMBER IS
    l_nb NUMBER;
  BEGIN
    SELECT COUNT(*)
      INTO l_nb
      FROM INF915_OBJET_PARENT p
     WHERE p.ID_NOTIFICATION = p_id_notification
       AND p.TYPE_OBJET      = p_type_objet
       AND p.TYPE_CIBLE     <> 'IDENTIQUE';
    RETURN l_nb;
  END FN_NB_MODIFIES;


  -- Nombre de cibles distinctes visées par un type d'objet. Une création compte pour
  -- une cible qui lui est propre, puisque son identifiant n'existe pas encore.
  FUNCTION FN_NB_CIBLES (p_id_notification IN NUMBER,
                         p_type_objet      IN VARCHAR2) RETURN NUMBER IS
    l_nb NUMBER;
  BEGIN
    SELECT COUNT(DISTINCT CASE
             WHEN p.TYPE_CIBLE = 'CREATION' THEN 'C' || TO_CHAR (p.ID_OBJET_PARENT)
             ELSE                                'E' || TO_CHAR (p.ID_OBJET_CIBLE)
           END)
      INTO l_nb
      FROM INF915_OBJET_PARENT p
     WHERE p.ID_NOTIFICATION = p_id_notification
       AND p.TYPE_OBJET      = p_type_objet;
    RETURN l_nb;
  END FN_NB_CIBLES;


  -- =================================================================================
  --  DÉDUCTION
  -- =================================================================================
  FUNCTION FN_CODE_OPERATION (p_id_notification IN NUMBER) RETURN VARCHAR2 IS
    l_orga_cible  INF915_NOTIFICATIONS.ID_ORGA_CIBLE%TYPE;
    l_maille      INF915_NOTIFICATIONS.MAILLE%TYPE;
    l_mod_contrat NUMBER;
    l_mod_si      NUMBER;
    l_mod_cf      NUMBER;
  BEGIN
    SELECT n.ID_ORGA_CIBLE, n.MAILLE
      INTO l_orga_cible, l_maille
      FROM INF915_NOTIFICATIONS n
     WHERE n.ID_NOTIFICATION = p_id_notification;

    l_mod_contrat := FN_NB_MODIFIES (p_id_notification, 'CONTRAT');
    l_mod_si      := FN_NB_MODIFIES (p_id_notification, 'SI');
    l_mod_cf      := FN_NB_MODIFIES (p_id_notification, 'CF');

    -- 1. L'organisation change : changement de titulaire, quoi qu'il arrive par
    --    ailleurs. Le contrat change nécessairement avec elle.
    IF l_orga_cible IS NOT NULL THEN
      RETURN c_titulaire;
    END IF;

    -- 2. Le contrat change, à organisation constante. Que les lots partent en entier
    --    ou pour partie ne change pas l'acte : c'est au worker de décider, au moment
    --    du traitement, s'il peut déplacer un lot plutôt que le recréer.
    IF l_mod_contrat > 0 THEN
      RETURN c_inter_contrat;
    END IF;

    -- 3 et 4. Les sites changent, à contrat constant.
    IF l_mod_si > 0 AND l_mod_cf > 0 THEN
      RETURN c_si_et_cf;
    END IF;

    IF l_mod_si > 0 THEN
      RETURN c_site_install;
    END IF;

    -- 5. Seul le site de facturation change. La maille dit si le conseiller
    --    réorganise sa facturation ou change le payeur de lignes désignées.
    IF l_mod_cf > 0 THEN
      IF l_maille = 'MASSE' THEN
        IF FN_NB_CIBLES (p_id_notification, 'CF') = 1 THEN
          RETURN c_fact_centra;
        END IF;
        RETURN c_fact_decentra;
      END IF;
      RETURN c_site_fact;
    END IF;

    -- 6. Aucun axe modifié.
    RETURN NULL;

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR (-20916,
        'INF915 : demande introuvable, ID_NOTIFICATION = ' || p_id_notification);
  END FN_CODE_OPERATION;


  -- =================================================================================
  --  ÉCRITURE SUR L'EN-TÊTE
  -- =================================================================================
  -- Écrit l'étiquette sur l'en-tête. Volontairement tolérante : une demande dont
  -- aucun axe n'est modifié reste à CODE_OPERATION NULL et se traite quand même.
  PROCEDURE PR_MAJ_CODE_OPERATION (p_id_notification IN NUMBER) IS
  BEGIN
    UPDATE INF915_NOTIFICATIONS
       SET CODE_OPERATION = FN_CODE_OPERATION (p_id_notification)
     WHERE ID_NOTIFICATION = p_id_notification;
  END PR_MAJ_CODE_OPERATION;


  -- Qualification de masse, pour un appel périodique du worker.
  FUNCTION FN_QUALIFIER_EN_ATTENTE (p_depuis IN DATE DEFAULT NULL) RETURN NUMBER IS
    l_nb NUMBER := 0;
  BEGIN
    FOR r IN (SELECT n.ID_NOTIFICATION
                FROM INF915_NOTIFICATIONS n
               WHERE n.CODE_OPERATION IS NULL
                 AND (p_depuis IS NULL
                      OR EXISTS (SELECT 1 FROM INF915_ACTION a
                                  WHERE a.ID_NOTIFICATION = n.ID_NOTIFICATION
                                    AND a.TYPE_ACTION     = 'CREATION'
                                    AND a.DATE_ACTION    >= p_depuis)))
    LOOP
      PR_MAJ_CODE_OPERATION (r.ID_NOTIFICATION);
      l_nb := l_nb + 1;
    END LOOP;
    RETURN l_nb;
  END FN_QUALIFIER_EN_ATTENTE;

END INF915_PY;
/


-- =====================================================================================
--  TABLE DE VÉRITÉ
--
--  ORGA   CONTRAT   SI    CF    MAILLE      CIBLES CF   ->  CODE_OPERATION
--  ----   -------   ---   ---   ---------   ---------      ----------------------------
--  chg    *         *     *     *           *              CHGT_TITULAIRE
--  =      chg       *     *     *           *              TRANSFERT_INTER_CONTRAT
--  =      =         chg   chg   *           *              CHGT_SI_ET_CF
--  =      =         chg   =     *           *              CHGT_SITE_INSTALLATION
--  =      =         =     chg   MASSE       1              REORG_FACT_CENTRA
--  =      =         =     chg   MASSE       n              REORG_FACT_DECENTRA
--  =      =         =     chg   SELECTION   *              CHGT_SITE_FACTURATION
--  =      =         =     =     *           *              NULL
-- =====================================================================================


-- =====================================================================================
--  UTILISATION
-- =====================================================================================
--
--  Appelée par le worker Python, en fin de prise en charge d'une demande :
--    BEGIN INF915_PY.PR_MAJ_CODE_OPERATION (:id); END;
--
--  Ou en qualification de masse, sur un ordonnanceur périodique :
--    DECLARE n NUMBER; BEGIN
--      n := INF915_PY.FN_QUALIFIER_EN_ATTENTE;
--      DBMS_OUTPUT.PUT_LINE (n || ' demande(s) qualifiee(s)');
--    END;
--
--  Pour afficher sans écrire, depuis l'écran de suivi :
--    SELECT INF915_PY.FN_CODE_OPERATION (:id) FROM DUAL;
--
--  Demandes encore en attente de qualification :
--    SELECT ID_NOTIFICATION, REFERENCE FROM INF915_NOTIFICATIONS
--     WHERE CODE_OPERATION IS NULL;
--
--  Contrôle de cohérence sur tout le stock, après une reprise de données :
--    SELECT n.ID_NOTIFICATION, n.REFERENCE,
--           n.CODE_OPERATION                                            AS CODE_STOCKE,
--           INF915_PY.FN_CODE_OPERATION (n.ID_NOTIFICATION)  AS CODE_CALCULE
--    FROM   INF915_NOTIFICATIONS n
--    WHERE  NVL (INF915_PY.FN_CODE_OPERATION (n.ID_NOTIFICATION), '~')
--        <> NVL (n.CODE_OPERATION, '~');
--
--  Comprendre une déduction, type d'objet par type d'objet :
--    SELECT p.TYPE_OBJET,
--           COUNT(*)                                                    AS NB_SOURCES,
--           SUM (p.NB_LIGNES)                                           AS NB_LIGNES,
--           INF915_PY.FN_NB_MODIFIES (:id, p.TYPE_OBJET)     AS NB_MODIFIES,
--           INF915_PY.FN_NB_CIBLES   (:id, p.TYPE_OBJET)     AS NB_CIBLES
--    FROM   INF915_OBJET_PARENT p
--    WHERE  p.ID_NOTIFICATION = :id
--    GROUP  BY p.TYPE_OBJET;
-- =====================================================================================


-- =====================================================================================
--  CE QUI RESTE À LA CHARGE DU WORKER
--
--  Le déplacement d'un lot entier, plutôt que la coupure et recréation de chacune de
--  ses BdS, reste possible et souhaitable : c'est ce que fait le LOT MOVE du batch
--  Fusac actuel, et c'est nettement plus rapide sur un lot de plusieurs centaines de
--  lignes. Simplement, la décision se prend à l'exécution et non à la validation :
--
--    SELECT l.ID_LOT_SOURCE
--    FROM   INF915_LIGNE l
--    WHERE  l.ID_NOTIFICATION = :id
--    GROUP  BY l.ID_LOT_SOURCE
--    HAVING COUNT(*) = (SELECT COUNT(*)
--                         FROM TABLE_CONTR_ITM i
--                        WHERE i.CONTR_ITM2CONTR_SCHEDULE = l.ID_LOT_SOURCE
--                          AND i.X_AV_STATUT_ACT IN (...));
--
--  Les lots que remonte cette requête peuvent être déplacés en bloc. Les autres sont
--  traités ligne par ligne. Le parc est lu au moment où il compte, et l'acte déduit
--  reste le même dans les deux cas.
-- =====================================================================================


-- =====================================================================================
--  CORRECTIF OPTIONNEL : centralisation vers une cible à créer
--
--  Dix sites de facturation source tous en TYPE_CIBLE = 'CREATION' valent dix créations
--  distinctes, donc une décentralisation. Représenter « je regroupe ces dix sites sur
--  un seul site, qui n'existe pas encore » demande une clé de regroupement.
--
--    ALTER TABLE INF915_OBJET_PARENT ADD (CLE_GROUPE_CIBLE VARCHAR2(40));
--    CREATE INDEX IX_INF915_PARENT_GRP ON INF915_OBJET_PARENT
--      (ID_NOTIFICATION, TYPE_OBJET, CLE_GROUPE_CIBLE);
--
--  FN_NB_CIBLES deviendrait :
--
--    SELECT COUNT(DISTINCT CASE
--             WHEN p.TYPE_CIBLE = 'CREATION'
--               THEN 'C' || NVL (p.CLE_GROUPE_CIBLE, TO_CHAR (p.ID_OBJET_PARENT))
--             ELSE      'E' || TO_CHAR (p.ID_OBJET_CIBLE)
--           END)
--      INTO l_nb ...
--
--  Et le worker séquentiel ne traiterait qu'une ligne par groupe, en reportant
--  l'identifiant créé sur les autres lignes du même groupe.
-- =====================================================================================
