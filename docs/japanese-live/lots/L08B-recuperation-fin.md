# L8B — Récupération de la dernière parole

## Dépendances

L8A au commit `69074d6`.

## Objectif

Rejouer une seule fois la queue PCM lorsqu'une parole VAD réelle reste après
la dernière émission utile Voxtral, sans doublon ni libération anticipée.

## Hors-périmètre

- Modifier les frontières japonaises, la configuration Q4/960 ou Apple.
- Ajouter un moteur, une dépendance ou une seconde tentative.
- Remplacer le transcript principal par une récupération vide.

## Fichiers touchés

- Aucun changement produit conservé après rollback.
- `docs/japanese-live/README.md` et cette fiche consignent la décision.

## Tests

- 12/12 replays temps réel du stress pack sans fausse reprise.
- Replays du PCM réel complet, cadencés à 1× dans le harness XCTest Release et
  hors réseau avec le premier prototype live. Ce ne sont pas des captures
  Firefox/ScreenCaptureKit.
- Cinq replays complets supplémentaires de `qudu2fx3ncc` pour isoler le seuil,
  l'EOS MLX, le chevauchement et le curseur PCM sûr.
- Les tests ciblés Swift restaient verts avant chaque replay, sans être archivés
  comme preuve produit.

## Preuves

- Les replays `Finish` avec 500 ms, 1 s et 1,5 s de chevauchement sont tous
  rejetés : le replay commence après le dernier texte utile et ne peut pas être
  dédupliqué sûrement.
- `l8b-voxtral-live-20260727T212500Z` : le seuil 5 s redémarre à tort les deux
  vidéos. `qudu` tombe à 87,9 % CER et perd toujours sa dernière parole;
  `md62` reste à 19,5 %.
- `l8b-voxtral-live-qudu-30s-20260727T221600Z` : 82,4 % CER, aucune parole
  finale récupérée.
- `l8b-voxtral-live-qudu-eos-20260727T224200Z` : le prototype d'attente EOS
  n'observe aucune nouvelle émission; le helper reste actif et accuse tout le
  PCM. CER 82,0 %.
- `l8b-voxtral-live-qudu-stall90-20260727T230500Z` : le chevauchement exact
  diverge et la déduplication refuse la finale.
- `l8b-voxtral-live-qudu-stall90-safe-20260727T232500Z` : le curseur PCM sûr
  récupère 1 070 caractères, mais avec des répétitions massives (`十` et
  phrases répétées). CER 78,8 %, dernière parole de référence toujours absente,
  dernier anglais 2,70 s, RSS 5,97 Gio, backlog final nul.
- Limites : les termes critiques restent non évaluables faute d'annotations
  humaines, les matrices sont incomplètes et les prototypes utilisent des
  arbres de sources différents mais épinglés par SHA. Ces preuves peuvent
  rejeter la reprise, pas promouvoir une version produit.

## Décision

Bloqué et rejeté. Aucun prototype ne respecte simultanément la dernière parole,
l'absence d'hallucination, la stabilité et la finale ≤1,5 s. L8C ne démarre pas.
Le défaut principal est un long flux Voxtral qui reste techniquement vivant
mais cesse de produire du texte; une nouvelle session tardive n'est pas assez
fidèle pour servir de récupération produit.

## Rollback

Appliqué : la récupération expérimentale et le patch runtime associé ont été
retirés. Le chemin continu L8A reste intact et le PCM non validé reste
récupérable.
