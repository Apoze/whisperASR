# E05 — locuteurs et parole superposée

## Protocole figé avant run

- Corpus exclusif : les deux vidéos et références déjà présentes dans `/Users/maz/Documents/videos/jap`.
- Contrôle : aucun signal locuteur/overlap. Candidats shadow-only : LS-EEND DIHARD3 100 ms, Sortformer fast v2.1 fp16 et Sortformer balanced v2.1 fp16.
- Deux expériences et processus distincts : `speaker-change`, puis `overlap`. Une seule variable : la présence et l'implémentation du signal shadow.
- Deux replays complets par vidéo, blocs de 1 600 échantillons, réseau sortant interdit, aucun retuning après observation.
- Aucun changement de `Sources/` ou `Package.swift`; le gate de Promotion des frontières reste fermé. Les captions, le VAD et les frontières ne consomment aucun résultat candidat.

## Autorité locale disponible

- `qudu2fx3ncc` : 199 tours, 22 changements exploitables, 18 plages d'overlap explicites totalisant 54,44 s. `SPEAKER_08`, `SPEAKER_13`, les tours non-high et les tours overlap sont exclus de la vérité de changement.
- `md62mmdz0m` : 271 tours, 99 changements exploitables, une intersection d'overlap de 1,77 s.
- Les deux manifestes sont `complete`, acceptés par Apoze, mais ne contiennent aucun `voiceChanges`. Les changements sont donc limités aux paires directement adjacentes, high, non-overlap et de locuteurs fiables; le collar de scoring fixé est ±500 ms.
- L'overlap positif est limité aux intersections temporelles des tours fournis et aux plages de réaction de groupe explicitement `SPEAKER_13`. Aucun autre intervalle n'est inventé.

## Portes figées

- Gain F1 apparié par vidéo : borne basse bootstrap 95 % > 0; précision et rappel ≥ 0,90 / 0,80 sur chaque vidéo.
- Changements : faux changements ≤ 0,1/minute scorée et latence p95 ≤ 1 500 ms.
- Overlap : faux positif ≤ 1 seconde/minute solo annotée.
- Live : bloc p95 ≤ 100 ms, pire ≤ 500 ms, RTF ≤ 1, timeline valide, déterminisme, thermique sans état serious/critical, mémoire sous la limite L0 +20 % et 10 Gio.
- Les portes preview, final, intégrité et mémoire `qwenApple` sont reprises du contrôle brut E4b épinglé; elles restent des veto.

## Résultat

Décision : **conserver l'absence de signal — preuve insuffisante**, séparément pour les changements de locuteur et l'overlap. Aucun candidat n'est promu.

| Candidat | Changements F1 Qudu / MD62 | Overlap F1 Qudu / MD62 |
|---|---:|---:|
| LS-EEND | 0,145 / 0,288 | 0,245 / 0,001 |
| Sortformer fast | 0,077 / 0,452 | 0,214 / 0,001 |
| Sortformer balanced | 0,084 / 0,476 | 0,194 / 0,001 |

- Les six expériences échouent les portes automatiques de précision/rappel. Les changements produisent 8,6 à 12,6 faux changements/minute; l'overlap produit 14,5 à 28,0 secondes de faux positif/minute solo.
- Temps réel, timeline, déterminisme et thermique passent pour tous. La mémoire combinée au contrôle E4b échoue pour tous; les portes preview et mémoire déjà rouges du contrôle E4b restent aussi des veto.
- `product-diff.txt` est vide et les tests confirment que le signal non promu ne peut modifier ni caption, ni VAD, ni frontière.

## Incidents runner diagnostiqués

- Le premier build hors Xcode échouait sur `XCTest`; il a été écarté avant candidat et corrigé par `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Le premier replay Sortformer dérivait d'environ 35 s. La cause est FluidAudio 0.15.5, pas le candidat : le correctif upstream local `baa11f65` cible les frames mel fantômes. Le run invalide a été écarté; le run officiel applique temporairement ces deux sources, sans changer modèle, seuil ou porte, puis restaure le checkout.

Artefacts officiels : `.build/benchmarks/japanese-live/runs/e5-diarization-20260807T073000Z/` — ensemble brut SHA-256 `852c8ebee97d6024c86f5f1e3215d6fc30403adeb25682b6d811369f261aeb12`, patch runner SHA-256 `3da463ef0ff40d2e8390e0629303de49878654da5baf792865de1bfea3193d97`.
