# L6 — Architectures live et anglais

## Dépendances

L5 au commit `25ffa22`. Les références restent `pending-human-review`; L6 peut comparer et écarter, pas promouvoir la qualité.

## Objectif

Séparer trois questions sur le PCM réel : qualité japonaise finale, qualité Apple anglaise sur cette source, et comportement d'une vraie preview temps réel.

## Hors-périmètre

- Simuler des préfixes en coupant un texte final.
- Utiliser l'anglais fourni comme vérité automatique.
- Intégrer un runtime produit ou créer L6A.
- Piloter Firefox; cette preuve appartient à L7.

## Périmètre concret

1. Traduire par Apple `lowLatency` et `highFidelity` les sorties japonaises L5, avec un contrôle japonais humain. Cette phase isole la traduction; elle n'est ni appelée preview live, ni utilisée comme preuve de final end-to-end.
2. Rejouer à vitesse réelle les fenêtres continues du stress pack. Apple Speech couvre une seule fois les quatre moteurs batch; WhisperLiveKit couvre sa propre architecture live.
3. Mesurer séparément couverture, première/dernière preview, révisions, final immuable, latences, backlog et ressources.

Voxtral et Nemotron ne sont pas rejoués ici : L5 les a déjà écartés sur le japonais final. Les charger de nouveau ne pourrait promouvoir aucun pipeline. La matrice 3 × 4 est réservée à une source qui survit au premier replay réel; aucune n'a franchi ce gate.

Fenêtres :

| Corpus | PCM | Durée |
| --- | --- | ---: |
| `qudu2fx3ncc` | 11 440 000–13 160 000 | 107,5 s |
| `qudu2fx3ncc` | 14 388 800–15 061 440 | 42,0 s |
| `md62mmdz0m` | 7 008 640–8 788 320 | 111,2 s |
| `md62mmdz0m` | 13 412 960–14 041 920 | 39,3 s |

## Fichiers touchés

Créés ou remplacés seulement quand leur rôle est nécessaire : oracle anglais L6, scripts de replay, support de preview partagé et cette documentation. Aucun changement produit ni `Package.swift` avant une victoire mesurée.

## Tests

- Décodage strict du rapport L5 schema 6 et des 8 moteurs.
- Apple Translation sur texte final, avec sorties `en-preview.json` et `en-final.json` nommées honnêtement comme stratégies isolées. Les omissions ASR et les échecs Apple sont comptés séparément.
- Replay PCM temps réel par blocs de 100 ms, avec arrêt anticipé si plusieurs SLO échouent nettement.
- WhisperLiveKit 0.2.24 au commit `5874bdee…`, encodeur MLX et décodeur/alignement PyTorch CPU; tous les SHA sont vérifiés et enregistrés.
- `ready_to_stop` obligatoire. Les extensions normales d'un préfixe ne sont pas des mutations. Sans frontière live sûre, seule la traduction stable du transcript complet à EOS est acceptée.
- Suite Swift complète, scripts shell/Python et replay avec réseau distant bloqué pour XCTest et le serveur WLK. Les services système Apple restent hors sandbox; la preuve globale sans cloud appartient à L7/L10.

## Preuves

Sous `.build/benchmarks/japanese-live/runs/<run-id>/` : rapports JSON, chronologie des préfixes, comparaison française et revue aveugle.

Résultats diagnostiques sur `qudu-fast-1` (`l6-apple-product-priority-precommit` et `l6-wlk-schema4-precommit`) :

| Source | Japonais | Preview anglaise | Final anglais | Mémoire | Décision |
| --- | --- | --- | --- | --- | --- |
| Apple Speech produit | CER 51,61 %, couverture 100 % | p50 1,131 s; p95 1,639 s; pire 2,744 s | finale Turbo/Kotoba mesurée séparément | 263 Mo observés, services Apple exclus | rate le p50 de 131 ms |
| WhisperLiveKit hybride | CER 52,69 %, couverture 85,71 % | p50 2,207 s; p95/pire 4,360 s | couverture 85,71 %; uniquement EOS, 25,034 s après fin du PCM | 13,41 Gio observés | écarté |

L'oracle Apple isolé contient 828 sources × 2 stratégies. Les échecs de couverture de Voxtral, Nemotron et `whispermlx` viennent de leurs omissions japonaises; Apple réussit sur chaque source japonaise non vide. La fidélité reste en attente de deux juges bilingues.

## Décision

Terminé sans promotion live. Apple Speech respecte couverture, p95 et pire, mais manque le p50. WhisperLiveKit échoue sur qualité japonaise, couverture, latence, frontières finales et mémoire; LocalAgreement n'est donc pas testé.

`whispermlx` reste un candidat batch arrêté en L5. L6A n'est pas créé, car aucune architecture MLX n'a d'abord franchi le gate ASR. L7 peut comparer Turbo et Kotoba dans Firefox à titre diagnostique, mais aucun des deux n'est promu avant la revue humaine et un SLO preview complet.

## Rollback

Revenir au commit L5; les outils et résultats L6 restent ignorés sous `.build`.
