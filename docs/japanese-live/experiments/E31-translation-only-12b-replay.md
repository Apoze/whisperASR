# Validation offline intégrée #106 — replay traduction 12B

Ce résultat est un replay traduction-only en processus frais sur amont E22 hashé. Pour la vidéo 1, ASR, alignement et spans SpeakerKit sont byte-identiques aux traces E31 normalisées ; le HighQualityJob courant vérifie aussi la requête de traduction exacte. Ce n’est pas un run intégré complet.

Configuration réelle : Qwen JA Standard, alignement et SpeakerKit/cues Standard, aucune récupération d’overlap ; 12B reste le défaut et 4B l’option bêta légère.

| Vidéo | Modèle | Route | CER JA | chrF++ | COMET | Total / RTF | ASR | Align. | SpeakerKit | Trad. | Mémoire | Intégrité/cues | Locuteurs/overlap |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| development | 12b | completed | 81.26 | 46.44 | 0.5540 | 14m 36.0s / 0.92× | 0m 0.0s | 0m 0.1s | 0m 0.7s | 14m 34.8s | 7.52 GiB; pression normal; swap -8 MiB | 0 rejet(s); 307 cues; >84c 59; >20c/s 224 | DER 105.47%; Δspk 7; overlap manqué/inventé 17.5/153.5s |
| holdout | 12b | completed | 25.77 | 49.02 | 0.6038 | 12m 46.0s / 0.86× | 0m 0.0s | 0m 0.0s | 0m 0.5s | 12m 44.5s | 7.50 GiB; pression normal; swap 0 MiB | 0 rejet(s); 260 cues; >84c 58; >20c/s 175 | DER 58.91%; Δspk 0; overlap manqué/inventé 1.7/92.7s |

## Comparaison concrète

- development — baseline E22 : CER 81.26 %, chrF++ 46.44, COMET 0.5540.
  - JA : はい、ありがとうございます。
    Référence : Yes—thank you very much.
    12B : Yes, thank you very much.
    4B : Yes, thank you.
  - JA : そうですね。 なんかよく似てるって言ってもらえるから、 もっと似れるように頑張ります。
    Référence : Yes. People often tell me that our play looks similar, so I'll work hard to become even more like him.
    12B : Yes, that's right. People often tell me I look quite similar, so... I'll work hard to look even more alike.
    4B : Yes, indeed. I’m being told that it looks remarkably similar, or that it has a very similar feel. I’ll keep trying to look more like them.
  - JA : このままはオーディシャッカーの時点で3番手なんだが、完全でした。
    Référence : That was perfect.
    12B : This way, we're currently in third place for the Audishacker, but it was perfect.
    4B : Despite being third in line as an auditor, this was completely satisfactory.
- holdout — baseline E22 : CER 25.77 %, chrF++ 49.02, COMET 0.6038.
  - JA : バグってるよ。
    Référence : It's bugged.
    12B : "It's bugged."
    4B : It’s not working properly.
  - JA : 全然関係ないんですけど、ずっ
    Référence : This is completely unrelated, but...
    12B : "It has absolutely nothing to do with it, but..."
    4B : It’s completely unrelated, but…
  - JA : これでいけるでしょ。
    Référence : This should work.
    12B : "Will this work?"
    4B : I think this should work, right?

## Décision

Les pannes de validation produit restent classées comme qualité modèle ; toute panne build, runner, référence ou sécurité interdit un verdict modèle.
This fresh-process replay validates translation quality and lifecycle on two hashed upstream artifacts; it is not a completed integrated run.

**NO_READY** pour le dernier run intégré 12B : la commande `full` existante relance aussi le 4B, hors du scope accordé. Aucune nouvelle variante n’est préparée.
