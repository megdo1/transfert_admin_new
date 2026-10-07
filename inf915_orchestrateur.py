#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
INF915 — Orchestrateur du transfert de parc.

Aucun paramètre de lancement. Tout est dans inf915.ini, cherché dans le répertoire
du script. Le programme fait deux choses, dans cet ordre :

    1. OBJETS PARENTS, une demande après l'autre
       Demandes en EN_ATTENTE, date d'effet atteinte, avec des objets à créer.
       Appelle INF915_PY.PR_CREER_OBJETS_PARENTS.
       À la sortie, la demande attend le feu vert du métier sur PARENTS_CREES.

    2. TRANSFERT DES LIGNES, N processus par demande
       Demandes en EN_ATTENTE_TRT_LIGNES, c'est-à-dire celles dont le métier a
       validé les objets créés. S'y ajoutent les demandes en EN_ATTENTE sans aucun
       objet à créer, qui n'ont rien à faire vérifier et sautent la passe 1.
       L'orchestrateur lit la liste des lignes et les distribue une par une à ses
       processus, chacun appelant INF915_PY.PR_TRAITER_LIGNE sur une seule ligne.

Les deux sélections sont disjointes : aucune demande ne peut être prise par les
deux. Une demande traitée par la première ne sera reprise par la seconde qu'à une
exécution ultérieure, une fois le feu vert donné. C'est le point d'arrêt métier, et
il ne découle d'aucune règle écrite ici : une demande sur PARENTS_CREES n'apparaît
simplement dans aucune des deux requêtes.

    inf915_orchestrateur.py

Compatible Python 3.7. Pilote : cx_Oracle, avec un client Oracle 11.2 ou supérieur.
python-oracledb en mode épais convient également, son API étant compatible ; seule
la ligne d'import change.
"""

import configparser
import logging
import logging.handlers
import os
import platform
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed

try:
    import cx_Oracle
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "INF915 : le pilote cx_Oracle est introuvable.\n"
        "         pip install cx_Oracle, avec un client Oracle 11.2 ou superieur.\n")
    raise


CONFIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'inf915.ini')

logger = logging.getLogger('inf915')

# Connexion propre au processus fils, ouverte par son initialisation.
_cnx_worker = None


# =====================================================================================
#  SÉLECTIONS
#
#  Une requête par passe, et ce sont les deux seules décisions du programme. Elles
#  sont disjointes, ce qui rend l'ordre des passes sans conséquence sur la correction.
# =====================================================================================

SQL_OBJETS_PARENTS = """
    SELECT ID_NOTIFICATION, REFERENCE, NB_OBJETS_A_CREER
      FROM INF915_NOTIFICATIONS
     WHERE STATUT            = 'EN_ATTENTE'
       AND NB_OBJETS_A_CREER > 0
       AND DATE_EFFET       <= TRUNC (SYSDATE)
     ORDER BY DATE_EFFET, ID_NOTIFICATION
"""

# EN_ATTENTE sans objet à créer entre ici directement : la passe 1 n'aurait rien créé
# et le point d'arrêt n'aurait rien à faire vérifier. Le trigger de transition autorise
# explicitement ce raccourci, et seulement dans ce cas.
SQL_LIGNES = """
    SELECT ID_NOTIFICATION, REFERENCE, NB_LIGNES
      FROM INF915_NOTIFICATIONS
     WHERE (   STATUT = 'EN_ATTENTE_TRT_LIGNES'
            OR (STATUT = 'EN_ATTENTE' AND NB_OBJETS_A_CREER = 0))
       AND DATE_EFFET <= TRUNC (SYSDATE)
     ORDER BY DATE_EFFET, ID_NOTIFICATION
"""

SQL_LIGNES_A_TRAITER = """
    SELECT ID_LIGNE
      FROM INF915_LIGNE
     WHERE ID_NOTIFICATION = :id
       AND STATUT          = 'A_TRAITER'
     ORDER BY ID_LIGNE
"""

SQL_STATUT = """
    SELECT STATUT, NB_LIGNES_OK,
           NB_LIGNES_KO_METIER + NB_LIGNES_KO_TECH, NB_OBJETS_CREES
      FROM INF915_NOTIFICATIONS
     WHERE ID_NOTIFICATION = :id
"""


# =====================================================================================
#  CONFIGURATION
# =====================================================================================

def lire_config():
    """Lit inf915.ini et renvoie un dictionnaire plat.

    Plat et sans objet, donc directement transmissible aux processus fils, qui ne
    partagent pas la mémoire du père et reçoivent tout par sérialisation."""

    if not os.path.isfile(CONFIG):
        raise IOError("fichier de configuration introuvable : {}".format(CONFIG))

    lecteur = configparser.ConfigParser()
    lecteur.read(CONFIG, encoding='utf-8')

    cfg = {
        'utilisateur':  lecteur.get('base', 'utilisateur'),
        'mot_de_passe': lecteur.get('base', 'mot_de_passe', fallback=''),
        'dsn':          lecteur.get('base', 'dsn'),
        'encodage':     lecteur.get('base', 'encodage', fallback='UTF-8'),

        'nb_process':               lecteur.getint('orchestrateur', 'nb_process', fallback=4),
        'minutes_avant_liberation': lecteur.getint('orchestrateur', 'minutes_avant_liberation', fallback=30),
        'intervalle_boucle':        lecteur.getint('orchestrateur', 'intervalle_boucle', fallback=0),

        'journal_niveau':    lecteur.get('journal', 'niveau', fallback='INFO'),
        'journal_fichier':   lecteur.get('journal', 'fichier', fallback=''),
        'journal_retention': lecteur.getint('journal', 'retention_jours', fallback=30),
    }

    if cfg['nb_process'] < 1:
        raise ValueError("nb_process doit valoir au moins 1")
    return cfg


def configurer_journal(cfg, suffixe=''):
    """Sortie standard, plus un fichier si la configuration en donne un. Le suffixe
    distingue le fichier des processus fils de celui du père."""

    niveau = getattr(logging, cfg.get('journal_niveau', 'INFO').upper(), logging.INFO)
    logger.setLevel(niveau)
    logger.handlers = []

    forme = logging.Formatter(
        '%(asctime)s %(levelname)-7s [%(process)d] %(message)s', '%Y-%m-%d %H:%M:%S')

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(forme)
    logger.addHandler(console)

    chemin = cfg.get('journal_fichier') or ''
    if not chemin:
        return

    if suffixe:
        base, ext = os.path.splitext(chemin)
        chemin = base + suffixe + ext
    try:
        repertoire = os.path.dirname(chemin)
        if repertoire:
            os.makedirs(repertoire, exist_ok=True)
        fichier = logging.handlers.TimedRotatingFileHandler(
            chemin, when='midnight', backupCount=cfg.get('journal_retention', 30),
            encoding='utf-8')
        fichier.setFormatter(forme)
        logger.addHandler(fichier)
    except OSError as err:
        logger.warning("journal fichier indisponible ({}), sortie standard seule".format(err))


# =====================================================================================
#  ACCÈS BASE
# =====================================================================================

def ouvrir_connexion(cfg):
    """Un mot de passe vide bascule sur l'authentification externe, Oracle Wallet
    notamment, où l'utilisateur vaut / et l'alias est celui du dsn."""

    if cfg['mot_de_passe']:
        cnx = cx_Oracle.connect(
            user=cfg['utilisateur'], password=cfg['mot_de_passe'], dsn=cfg['dsn'],
            encoding=cfg['encodage'], nencoding=cfg['encodage'])
    else:
        cnx = cx_Oracle.connect(
            dsn=cfg['dsn'], externalauth=True,
            encoding=cfg['encodage'], nencoding=cfg['encodage'])

    cnx.callTimeout = 0        # les traitements de masse sont longs par nature
    return cnx


def lister(cfg, sql, id_notification=None):
    """Exécute une requête de sélection et renvoie ses lignes sous forme de tuples."""
    cnx = ouvrir_connexion(cfg)
    try:
        cur = cnx.cursor()
        try:
            if id_notification is None:
                cur.execute(sql)
            else:
                cur.execute(sql, id=id_notification)
            return cur.fetchall()
        finally:
            cur.close()
    finally:
        cnx.close()


def appeler(cfg, procedure, arguments):
    """Appel d'une procédure du package, connexion ouverte et refermée autour."""
    cnx = ouvrir_connexion(cfg)
    try:
        cur = cnx.cursor()
        try:
            cur.callproc(procedure, arguments)
        finally:
            cur.close()
    finally:
        cnx.close()


def lire_statut(cfg, id_notification):
    lignes = lister(cfg, SQL_STATUT, id_notification)
    return lignes[0] if lignes else (None, 0, 0, 0)


def identite_worker():
    """Identifiant porté par ID_WORKER, colonne VARCHAR2(60). Doit rester unique par
    processus pour que PR_LIBERER_LIGNES sache ce qu'un worker donné détenait."""
    return "{}:{}".format(platform.node(), os.getpid())[:60]


# =====================================================================================
#  PASSE 1 — OBJETS PARENTS
#
#  Une demande après l'autre, dans le processus courant. Aucun pool, aucun fils : le
#  seul endroit du programme qui en crée est transferer_lignes, dans la passe 2.
#
#  Séquentiel par nécessité, pas par prudence. À l'intérieur d'une demande, la
#  procédure PL/SQL crée les objets dans l'ordre de leurs dépendances, un lot
#  référençant le contrat et les sites créés juste avant. Et d'une demande à l'autre,
#  le volume ne justifie rien d'autre : quelques dizaines d'objets là où les lignes se
#  comptent en milliers.
# =====================================================================================

def passe_objets_parents(cfg):
    demandes = lister(cfg, SQL_OBJETS_PARENTS)
    if not demandes:
        logger.info("objets parents : aucune demande a traiter")
        return 0

    logger.info("objets parents : {} demande(s), traitees une par une".format(len(demandes)))
    traitees = 0

    for id_notif, reference, nb_objets in demandes:
        logger.info("  {} : creation de {} objet(s)".format(reference, nb_objets))
        debut = time.time()
        try:
            appeler(cfg, 'INF915_PY.PR_CREER_OBJETS_PARENTS',
                    [id_notif, identite_worker()])
        except cx_Oracle.DatabaseError as err:
            logger.error("  {} : echec, {}".format(reference, err))
            continue

        statut, _, _, nb_crees = lire_statut(cfg, id_notif)
        logger.info("  {} : {}, {} objet(s) cree(s) en {:.1f} s".format(
            reference, statut, nb_crees or 0, time.time() - debut))
        traitees += 1

    return traitees


# =====================================================================================
#  PASSE 2 — TRANSFERT DES LIGNES
#
#  Les demandes restent traitées une par une, mais chacune mobilise N processus.
#
#  L'orchestrateur lit la liste des lignes et en soumet une par tâche. C'est le pool
#  qui répartit : dès qu'un processus a fini sa ligne, il prend la suivante. La charge
#  s'équilibre donc d'elle-même, quelles que soient les disparités de durée entre une
#  ligne à une seule BdS et une ligne à quinze. Aucune taille de lot à régler, et aucun
#  processus ne se retrouve à attendre pendant qu'un autre finit son paquet.
#
#  La prise reste protégée côté base : PR_TRAITER_LIGNE ne traite la ligne que si elle
#  est encore en A_TRAITER, ce qui rend inoffensif un double lancement.
# =====================================================================================

def initialiser_worker(cfg):
    """Exécuté une fois par processus fils, à sa création. Une connexion Oracle ne se
    partage pas entre processus : chacun ouvre la sienne et la garde pour toutes les
    lignes qu'il traitera."""
    global _cnx_worker
    configurer_journal(cfg, suffixe='.worker')
    _cnx_worker = ouvrir_connexion(cfg)


def traiter_une_ligne(cfg, id_ligne):
    """Traite une ligne et une seule. PR_TRAITER_LIGNE gère sa propre transaction et ne
    remonte jamais d'exception : une ligne en échec est consignée en base, le processus
    reste disponible pour la suivante.

    Fonctionne dans les deux cas : lancée par le pool, elle réutilise la connexion posée
    par initialiser_worker ; appelée directement quand nb_process vaut 1, elle ouvre et
    referme la sienne."""

    global _cnx_worker
    propre = _cnx_worker is None
    cnx = ouvrir_connexion(cfg) if propre else _cnx_worker

    cur = cnx.cursor()
    try:
        cur.callproc('INF915_PY.PR_TRAITER_LIGNE', [id_ligne, identite_worker()])
    finally:
        cur.close()
        if propre:
            cnx.close()


def transferer_lignes(cfg, id_notification, nb_lignes):
    """Distribue les lignes de la demande et attend qu'elles soient toutes traitées."""

    lignes = [l[0] for l in lister(cfg, SQL_LIGNES_A_TRAITER, id_notification)]
    if not lignes:
        logger.info("    aucune ligne en attente")
        return

    nb = max(1, cfg['nb_process'])
    jalon = max(1, len(lignes) // 10)      # une trace tous les dix pour cent

    if nb == 1:
        for rang, id_ligne in enumerate(lignes, 1):
            traiter_une_ligne(cfg, id_ligne)
            if rang % jalon == 0:
                logger.info("    {} / {} lignes".format(rang, len(lignes)))
        return

    faites = 0
    echecs = 0
    with ProcessPoolExecutor(max_workers=nb,
                             initializer=initialiser_worker,
                             initargs=(cfg,)) as pool:
        futurs = [pool.submit(traiter_une_ligne, cfg, id_ligne) for id_ligne in lignes]

        for futur in as_completed(futurs):
            err = futur.exception()
            if err is not None:
                # PR_TRAITER_LIGNE consigne elle-même les erreurs metier et techniques :
                # arriver ici signale un incident du processus, connexion perdue par
                # exemple, pas une ligne en echec.
                echecs += 1
                if echecs <= 5:
                    logger.error("    incident sur un processus : {}".format(err))
            faites += 1
            if faites % jalon == 0:
                logger.info("    {} / {} lignes".format(faites, len(lignes)))

    if echecs:
        logger.warning("    {} incident(s) de processus sur {} ligne(s)".format(
            echecs, len(lignes)))
    if echecs == len(lignes):
        # Aucune ligne n'a pu être soumise : problème commun, connexion ou droits.
        raise RuntimeError("toutes les lignes ont echoue au niveau processus")


def passe_lignes(cfg):
    demandes = lister(cfg, SQL_LIGNES)
    if not demandes:
        logger.info("transfert des lignes : aucune demande a traiter")
        return 0

    logger.info("transfert des lignes : {} demande(s), {} processus par demande".format(
        len(demandes), cfg['nb_process']))
    traitees = 0

    for id_notif, reference, nb_lignes in demandes:
        logger.info("  {} : {} ligne(s)".format(reference, nb_lignes))

        # Un worker tué laisse sa ligne en EN_COURS, et elle ne serait plus reprise :
        # la sélection des lignes à traiter ne retient que A_TRAITER.
        if cfg['minutes_avant_liberation']:
            try:
                appeler(cfg, 'INF915_PY.PR_LIBERER_LIGNES',
                        [id_notif, None, cfg['minutes_avant_liberation']])
            except cx_Oracle.DatabaseError as err:
                logger.warning("  {} : remise en file impossible, {}".format(reference, err))

        debut = time.time()
        try:
            appeler(cfg, 'INF915_PY.PR_DEBUT_LIGNES', [id_notif, identite_worker()])
            transferer_lignes(cfg, id_notif, nb_lignes)
            appeler(cfg, 'INF915_PY.PR_CLOTURER', [id_notif, identite_worker()])
        except Exception as err:
            logger.error("  {} : echec, {}".format(reference, err))
            continue

        statut, nb_ok, nb_ko, _ = lire_statut(cfg, id_notif)
        logger.info("  {} : {}, {} transferee(s), {} en erreur, en {:.1f} s".format(
            reference, statut, nb_ok or 0, nb_ko or 0, time.time() - debut))
        traitees += 1

    return traitees


# =====================================================================================
#  POINT D'ENTRÉE
# =====================================================================================

def executer(cfg):
    """Une exécution complète : la passe 1, puis la passe 2."""
    passe_objets_parents(cfg)
    passe_lignes(cfg)


def main():
    try:
        cfg = lire_config()
    except (IOError, ValueError, configparser.Error) as err:
        sys.stderr.write("INF915 : configuration invalide, {}\n".format(err))
        return 2

    configurer_journal(cfg)

    # intervalle_boucle à zéro : une exécution puis sortie, la répétition revenant à
    # l'ordonnanceur. Sinon le programme reste en vie et recommence après ce délai.
    # Les deux modes partagent la même boucle, exécutée au moins une fois, et ne
    # diffèrent que par leur sortie et par le traitement d'une erreur.
    # intervalle_boucle à zéro : une exécution puis sortie, la répétition revenant à
    # l'ordonnanceur. Sinon le programme reste en vie et recommence après ce délai.
    #
    # Aucun arrêt propre n'est prévu, et il n'en faut pas : chaque ligne transférée est
    # une transaction complète, validée ou annulée. Un arrêt brutal laisse au pire une
    # ligne par processus à EN_COURS, que la remise en file reprendra au passage
    # suivant. Rien n'est perdu, rien n'est à moitié fait.
    while True:
        code = 0
        try:
            executer(cfg)
        except cx_Oracle.DatabaseError as err:
            logger.error("erreur Oracle : {}".format(err))
            code = 4
        except Exception as err:
            logger.exception("erreur inattendue : {}".format(err))
            code = 5

        # En exécution unique, le code de retour renseigne l'ordonnanceur. En mode
        # permanent, l'erreur a été journalisée et le prochain passage retentera.
        if not cfg['intervalle_boucle']:
            return code

        time.sleep(cfg['intervalle_boucle'])


if __name__ == '__main__':
    sys.exit(main())
