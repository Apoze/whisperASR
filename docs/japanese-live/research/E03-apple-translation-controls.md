# E03 — contrôles de registre et de terminologie dans Apple Translation

Date d'accès : 2026-08-06. Base : `06a1bbc015e9`. Périmètre : API publiques Apple `TranslationSession` pour une traduction japonaise vers l'anglais. Aucun autre moteur ni aucune sortie de benchmark n'ont été consultés.

## Conclusion

**Preuve insuffisante : aucune API supportée n'a été trouvée pour imposer un registre, un style, un domaine ou une correspondance de glossaire japonais → anglais à `TranslationSession`.** C'est une absence dans la surface publique Apple examinée à cette date, pas une preuve sur le fonctionnement interne des modèles ni sur de futures API.

Apple expose la langue source, la langue cible, le texte et, depuis macOS 26.4, le choix entre une stratégie de fidélité et une stratégie de latence. Aucune de ces entrées n'accepte d'instruction linguistique ni de table terme source → terme cible.

macOS 26.4 ajoute aussi `AttributeScopes.TranslationAttributes.skipsTranslation`. Ce mécanisme supporté laisse une plage source inchangée ; il ne lui assigne pas une traduction anglaise. Il peut donc préserver tel quel un nom déjà écrit dans la graphie voulue, mais ne constitue pas un glossaire JA→EN et ne contrôle ni le registre ni le domaine.

La condition préalable du ticket n'est pas satisfaite : ne pas lancer de comparaison de profils de domaine, ne pas changer de moteur, ne pas préfixer ou modifier le japonais, et ne pas transformer le glossaire en post-correcteur anglais. Apple Translation reste sans contexte.

## Surface publique vérifiée

| Besoin | API Apple exacte | Disponibilité | Limite observée |
| --- | --- | --- | --- |
| Choisir les langues | `TranslationSession.Configuration.init(source:target:)`, `source`, `target` | macOS 15.0+ | Langues seulement. |
| Traduire | `translate(_ string: String)`, `translate(batch:)`, `translations(from:)` | macOS 15.0+ | Le contenu traduit est l'unique entrée sémantique. |
| Identifier une requête | `TranslationSession.Request.init(sourceText:clientIdentifier:)` | macOS 15.0+ | `clientIdentifier` raccorde seulement requête et réponse. |
| Choisir le modèle | `TranslationSession.Strategy.highFidelity`, `.lowLatency`, `Configuration.init(source:target:preferredStrategy:)` | macOS 26.4+ | Arbitrage modèle/qualité/latence ; aucun réglage de ton, domaine ou terminologie. |
| Conserver une plage | `translate(_ string: AttributedString)`, `skipsTranslation = true` | macOS 26.4+ | Exclut la plage de la traduction ; aucune correspondance vers un terme anglais. |

L'interface Swift publique livrée par Apple dans le SDK macOS 26.5 installé (`Translation.framework/Modules/Translation.swiftmodule/arm64e-apple-macos.swiftinterface`) confirme cet inventaire : `TranslationSession.Configuration` ne contient que `source`, `target`, `version` et `preferredStrategy`; `TranslationSession.Request` ne contient que le texte, sa variante attribuée et `clientIdentifier`; le seul attribut défini par la portée Translation est `skipsTranslation`.

## Sources Apple primaires

Toutes les sources ont été consultées le 2026-08-06.

- [TranslationSession — Apple Developer Documentation](https://developer.apple.com/documentation/translation/translationsession) : classe disponible à partir de macOS 15.0 ; inventaire des traductions unitaires et batch.
- [TranslationSession.Configuration — Apple Developer Documentation](https://developer.apple.com/documentation/translation/translationsession/configuration) : `source`, `target`, `invalidate()`, `version`, puis `preferredStrategy` sur macOS 26.4+.
- [TranslationSession.Request — Apple Developer Documentation](https://developer.apple.com/documentation/translation/translationsession/request) : `sourceText` et `clientIdentifier` sur macOS 15.0+.
- [TranslationSession.Strategy — Apple Developer Documentation](https://developer.apple.com/documentation/translation/translationsession/strategy) et [init(source:target:preferredStrategy:)](https://developer.apple.com/documentation/translation/translationsession/configuration/init%28source%3Atarget%3Apreferredstrategy%3A%29) : `highFidelity` utilise Apple Intelligence quand disponible avec repli, `lowLatency` les modèles traditionnels ; macOS 26.4+.
- [translate(_:) avec AttributedString — Apple Developer Documentation](https://developer.apple.com/documentation/translation/translationsession/translate%28_%3A%29-59zi2) et [skipsTranslation — Apple Developer Documentation](https://developer.apple.com/documentation/foundation/attributescopes/translationattributes/skipstranslation) : préservation du formatage et exclusion explicite de plages ; macOS 26.4+.
- [Meet the Translation API — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10117/) : Apple présente le choix source/cible, les appels unitaires ou batch, la disponibilité et les téléchargements ; aucun contrôle de registre, domaine ou glossaire n'est exposé.

Apple documente par ailleurs des glossaires et consignes de ton pour les **agents de localisation dans Xcode 27** dans [Translate your app using agents in Xcode — WWDC26](https://developer.apple.com/videos/play/wwdc2026/213/). Il s'agit de localisation de String Catalogs par agents, pas de l'API runtime `TranslationSession`; cette capacité ne peut donc pas être transposée au flux live.
