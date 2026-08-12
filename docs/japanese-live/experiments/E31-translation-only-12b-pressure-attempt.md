# #106 — replay traduction-only 12B interrompu par pression native

Verdict : **INCONCLUSIVE_RUNTIME_MEMORY_PRESSURE**. Aucun verdict qualité 12B et aucun sous-titre anglais publié.

- Vidéo 1 : 76/307 cues terminés, puis `warning`; cleanup demandé, nouvel échantillon encore `warning`, arrêt propre à 136 s.
- Mémoire : pic footprint 10,36 GiB, pic RSS 2,17 GiB, minimum libre 30 %, swap +0, pression revenue à `normal` et 71 % libre après sortie.
- Lifecycle : worker 12B frais sorti sans terminaison forcée; aucun worker résident. Vidéo 2 non lancée.
- Entrée : hash invariant `turns + glossary + glossaryByCueID` identique aux replays E22/E31 4B.
- Qualité : chrF++/COMET/intégrité indisponibles honnêtement, car le produit est incomplet.

Conclusion : **NO_READY** pour un dernier run intégré 12B. Le cleanup à la frontière de la requête arrive après les 307 cues; il ne borne pas la croissance au sein de cette requête.
