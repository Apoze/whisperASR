# Validation offline intégrée #106 — replay traduction 4B

La campagne #106 reste **INCONCLUSIVE_RUNTIME_MEMORY_PRESSURE** : ce run valide uniquement le 4B et ne produit aucun verdict qualité 12B. Voir la [preuve brute 12B](evidence/E31-12b-pressure-attempt/report.json).

Ce résultat est un replay traduction-only en processus frais sur amont E22 hashé. Pour la vidéo 1, ASR, alignement et spans SpeakerKit sont byte-identiques aux traces E31 normalisées ; le HighQualityJob courant vérifie aussi la requête de traduction exacte. Ce n’est pas un run intégré complet.

Configuration réelle : Qwen JA Standard, alignement et SpeakerKit/cues Standard, aucune récupération d’overlap ; 12B reste le défaut et 4B l’option bêta légère.

| Vidéo | Modèle | Route | CER JA | chrF++ | COMET | Total / RTF | ASR | Align. | SpeakerKit | Trad. | Mémoire | Intégrité/cues | Locuteurs/overlap |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| development | 4b | model-quality-rejection | 81.26 | 42.57 | 0.5462 | 5m 4.0s / 0.32× | 0m 0.0s | 0m 0.0s | 0m 0.7s | 5m 2.9s | 5.15 GiB; pression normal; swap -16 MiB | 14 rejet(s); 0 cues; >84c 0; >20c/s 0 | DER 105.47%; Δspk 7; overlap manqué/inventé 17.5/153.5s |
| holdout | 4b | model-quality-rejection | 25.77 | 46.74 | 0.5823 | 4m 17.0s / 0.29× | 0m 0.0s | 0m 0.0s | 0m 0.5s | 4m 16.5s | 5.20 GiB; pression normal; swap 0 MiB | 9 rejet(s); 0 cues; >84c 0; >20c/s 0 | DER 58.91%; Δspk 0; overlap manqué/inventé 1.7/92.7s |

## Comparaison concrète

- development — baseline E22 : CER 81.26 %, chrF++ 46.44, COMET 0.5540.
  - JA : はい、ありがとうございます。
    Référence : Yes—thank you very much.
    12B (E22 historique): Yes, thank you very much.
    4B : Yes, thank you.
  - JA : そうですね。 なんかよく似てるって言ってもらえるから、 もっと似れるように頑張ります。
    Référence : Yes. People often tell me that our play looks similar, so I'll work hard to become even more like him.
    12B (E22 historique): Yes, that's right. People often tell me I look quite similar, so... I'll work hard to look even more alike.
    4B : Yes, indeed. I’m being told that it looks remarkably similar, or that it has a very similar feel. I’ll keep trying to look more like them.
  - JA : このままはオーディシャッカーの時点で3番手なんだが、完全でした。
    Référence : That was perfect.
    12B (E22 historique): This way, we're currently in third place for the Audishacker, but it was perfect.
    4B : Despite being third in line as an auditor, this was completely satisfactory.
- holdout — baseline E22 : CER 25.77 %, chrF++ 49.02, COMET 0.6038.
  - JA : バグってるよ。
    Référence : It's bugged.
    12B (E22 historique): "It's bugged."
    4B : It’s not working properly.
  - JA : 全然関係ないんですけど、ずっ
    Référence : This is completely unrelated, but...
    12B (E22 historique): "It has absolutely nothing to do with it, but..."
    4B : It’s completely unrelated, but…
  - JA : これでいけるでしょ。
    Référence : This should work.
    12B (E22 historique): "Will this work?"
    4B : I think this should work, right?

## Décision

Les pannes de validation produit restent classées comme qualité modèle ; toute panne build, runner, référence ou sécurité interdit un verdict modèle.
This fresh-process replay validates translation quality and lifecycle on two hashed upstream artifacts; it is not a completed integrated run.
