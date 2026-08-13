# E05 — contexte lexical Apple

Date : 2026-08-02. Machine : MacBook Pro M5 Pro 24 Gio, macOS 26.5.2. Source : commit propre `61fc757356059e00892a51abe4f7c58298ae8ef0`. Run : `e5-apple-context-20260802T150952Z`.

## Décision expérimentale

Ne promouvoir aucune des quatre configurations de contexte lexical Apple testées. Aucun profil n'améliore le rappel exact des noms et termes critiques : le F1 reste à 0 en preview et sur les événements Apple stabilisés. La porte CER n'est pas bloquante, mais elle ne suffit pas à retenir une configuration sans gain lexical.

Cette décision ne modifie pas le produit : le sélecteur utilisateur reste par défaut sur `General only`, qui continue actuellement à fournir les termes canoniques à Apple Speech et à piloter les corrections déterministes du glossaire. La désactivation de ces hints dans le produit relève d'un changement séparé.

| Profil | Configuration | Termes | F1 preview | F1 Apple `isFinal` | CER holdout | Δ CER vs off |
|---|---|---:|---:|---:|---:|---:|
| général | off | 0 | 0,00 | 0,00 | 43,53 % | — |
| général | canonique | 16 | 0,00 | 0,00 | 42,23 % | −1,29 pt |
| général | canonique + kana | 32 | 0,00 | 0,00 | 42,39 % | −1,13 pt |
| VSPO | off | 0 | 0,00 | 0,00 | 43,53 % | — |
| VSPO | canonique | 49 | 0,00 | 0,00 | 42,56 % | −0,97 pt |
| VSPO | canonique + kana | 98 | 0,00 | 0,00 | 43,53 % | 0,00 pt |

Le seuil de dégradation de deux points est respecté partout. Cependant, aucun des 39 replays ciblés ne contient la forme attendue dans les revisions de preview ou dans les événements Apple `isFinal`. Les lectures kana produisent parfois des approximations comme `あまりもか`, sans restaurer `甘結もか`.

## Protocole

- Service réel `AppleSpeechService.start(contextualStrings:)`, locale `ja-JP`.
- Replay à vitesse réelle par blocs de 100 ms avec la finalisation progressive produit toutes les 1,5 s.
- Preview : tous les événements révisables `isFinal == false`. Stabilisé Apple : événements `isFinal == true`. Le Final produit Qwen n'est pas exécuté ni évalué ici.
- Général : `VCR GTA`, `VTuber` et deux occurrences d'`APEX`.
- VSPO : les quatre cas général, quatre occurrences de `甘結もか` et une occurrence de `VSPO`.
- Holdout CER : `md62-dialogue-1` et `md62-dialogue-2`, soit 618 caractères de référence sans terme ciblé.
- Critère : retenir une configuration seulement si son F1 lexical dépasse strictement `off` et si sa CER ne régresse pas de plus de deux points.

## Reproductibilité

- Modèle : `SpeechTranscriber` Apple géré par macOS ; aucun fichier de modèle ni SHA n'est exposé (`N/A`).
- Couverture PCM d'entrée : 100 % de chaque clip ciblé et holdout a été envoyé, de l'échantillon 0 à la fin du clip ; aucune erreur d'alimentation n'a été relevée. Cette valeur décrit l'alimentation du transcriber, pas la couverture textuelle de sa sortie.
- Latences : non enregistrées dans E5, car elles ne participent pas à la porte lexicale/CER. Le replay reste cadencé en temps réel par blocs de 100 ms, avec finalisation progressive toutes les 1,5 s.

## Preuves

Le run contient 39 résultats ciblés, 10 résultats holdout et aucune erreur. Les holdouts ont produit 477 à 500 événements de preview et 77 à 79 événements Apple stabilisés selon la configuration.

Corpus certifiés :

- `qudu2fx3ncc` — audio SHA-256 `494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2`, manifeste SHA-256 `a13a80fed1c02ee9c79ff58d6d7c2bf7050a16733ced48c33121dc4d414b5c0b`.
- `md62mmdz0m` — audio SHA-256 `bde49d4cc67020d01ae042f2945baa61364cc34959e2211a964943e5c2064830`, manifeste SHA-256 `9e2c828804457100b5f517ae84e1709a7b502837e36154ec4e7c7b5dc635e3bc`.

Rapport brut local : `.build/benchmarks/japanese-live/runs/e5-apple-context-20260802T150952Z/apple-context.json`.
