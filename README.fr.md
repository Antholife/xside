# XSide

[English](README.md) · **Français**

XSide est une app de la barre des menus de macOS qui installe des fichiers `.ipa` sur ton iPhone et ton iPad avec un compte Apple gratuit, et les rafraîchit automatiquement avant l'expiration des 7 jours imposée par Apple.

Elle utilise uniquement les outils d'Xcode (`xcodebuild`, `codesign`, `devicectl`). XSide ne demande jamais ton mot de passe Apple : la signature passe par le compte que tu as déjà ajouté dans Xcode.

## Fonctionnalités

- Glisse un `.ipa` sur l'icône de la barre des menus (ou choisis-le) et installe-le sur un ou plusieurs appareils.
- Rafraîchissement automatique en USB ou en Wi-Fi (au choix par appareil), 2 jours avant l'expiration.
- Rappels avant l'expiration, pastille sur l'icône quand il faut agir, et notifications qui ouvrent le bon endroit pour corriger.
- Menu par app : rafraîchir maintenant, mettre en pause, désinstaller de l'appareil.
- L'icône de l'app, ses appareils et les jours restants d'un coup d'œil.
- Premier lancement guidé : Xcode, Apple Account, certificat de signature, notifications, appareils.
- En français et en anglais.

## Prérequis

- Un Mac sous **macOS 15 ou plus récent**.
- **Xcode**, installé dans `/Applications` et ouvert une fois. Si ton iPhone est sous une bêta d'iOS, il te faut la bêta d'Xcode correspondante ([developer.apple.com/download/applications](https://developer.apple.com/download/applications/)).
- Un **compte Apple** ajouté dans Xcode > Settings > Apple Accounts (Réglages > Comptes Apple). Un compte gratuit suffit.
- Le mode développeur activé sur l'appareil, et l'appareil appairé une fois au Mac en USB.

Windows et Linux ne sont pas pris en charge : XSide repose sur Xcode, qui ne tourne que sur macOS.

## Les limites d'Apple avec un compte gratuit

- Les apps expirent au bout de **7 jours** : XSide les re-signe et les réinstalle avant, tant qu'il tourne dans la barre des menus.
- **3 apps installées ainsi** au maximum par appareil.
- **10 App ID** par période de 7 jours. XSide affiche une estimation de ce qu'il reste, car Apple ne donne pas le vrai chiffre.
- Les extensions (widgets, extensions de partage, apps Watch) sont retirées avant la signature.

## Installation

Il n'y a pas encore de version signée, il faut donc la compiler :

```sh
git clone https://github.com/Antholife/xside.git
cd xside
scripts/bundle.sh   # crée build/XSide.app
```

Mets `build/XSide.app` dans `/Applications` et ouvre-la. L'app n'est pas notarisée : si macOS la bloque, va dans **Réglages Système > Confidentialité et sécurité** et clique sur **Ouvrir quand même**.

Laisse XSide tourner dans la barre des menus (active *Lancer à l'ouverture de session* dans ses réglages) : c'est lui qui rafraîchit tes apps.

## Développement

- `swift build` / `swift test` : la logique se trouve dans `Sources/XSideCore`, avec ses tests.
- `CONFIG=debug scripts/bundle.sh` crée `build/XSide-debug.app`, une app séparée (identifiant et données à part) pour les tests.
- `scripts/check-strings.sh` vérifie que les textes français et anglais correspondent.

## Licence

[MIT](LICENSE) · Par [Antholife](https://github.com/Antholife)
