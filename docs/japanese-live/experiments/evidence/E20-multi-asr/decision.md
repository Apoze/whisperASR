# Décision multi-ASR figée — ticket #64

## Décision

**Rejet du candidat multi-ASR. Qwen reste la stratégie.** Aucun réglage produit ni Live n'a été modifié, et le holdout est resté fermé.

## Pourquoi

- Le CER japonais DEV baisse de 86.83% à 79.64%.
- Mais le gain relatif apparié vaut 8.27% et sa borne basse à 95% vaut -2.04% ; la porte exige au moins +10%.
- Le candidat ajoute 8 tour(s) de parole vide(s).
- Exemple gagné : « リーサルだー！ ドーーーン!!! » est moins noyé dans le texte voisin.
- Exemple perdu : « VCR GTAで人のパンツ覗いてきた人のことなんか、ボコボコにしてくれ。 » devient « か » au lieu de « たgtaで人のパンツ覗いてきた人のことなんか報告にしてくれ » avec Qwen.

## Coût et sécurité

- Les six sorties ASR existantes ont été réutilisées et leurs hashes revérifiés ; aucun ASR n'a été relancé.
- WhisperKit n'a été utilisé que sur les 16 désaccords Qwen/Parakeet ; médoïde complète puis ROVER strict 2/3 ; une seule traduction.
- Surcoût ASR figé : 527.359s / budget 527.4s. Exécution candidate observée : 375.0s.
- Modèles lourds séquentiels, réserve fixe 0, aucun événement warning/critical. Pic processus 18.42 Go, minimum disponible 2.70 Go, swap 2.93 → 6.26 Go (pic 10.87 Go).

## Anglais et cues

La traduction unique régresse aussi : chrF++ 45.44 → 42.08, hallucinations signalées 11 → 16, et marqueurs natifs manqués 61 → 93.

- Cue gagnée : « Both players are being extremely cautious. » devient « This is difficult to counter. Both sides are being very cautious. », au lieu de la digression Qwen sur un “American mocha”.
- Cue perdue : « And it works. Three bars remain. » devient vide.
- Terme perdu en sens : « しっかりと対応してきた投げさせましたバーンアウトしてるとよくなさそうなんですけど » garde le mot “Burnout”, mais « "I'm concerned that they're showing signs of burnout, despite our efforts to support them." » transforme l'état de jeu en fatigue humaine.
- Autre inversion de sens conservée dans les preuves : « 豪鬼は…HPが少ない » devient “Gouki has more HP”.

COMET n'a pas été lancé : le japonais, chrF++ et les hallucinations avaient déjà rejeté le candidat ; ce modèle lourd ne pouvait plus changer la décision.

## Vérifications

Le self-test du reporter, la garde séquentielle, le job DEV réel et le lancement de l'app passent. La suite complète exécute 377 tests mais conserve 5 cas en échec : la référence E13 ne correspond plus au catalogue, et quatre contrôles de traduction rencontrent la réserve produit fixe de 8 Go après l'expérience lourde. Ces échecs se reproduisent hors candidat et relèvent déjà de #47 ; aucune valeur produit ni référence n'a été modifiée ici.
