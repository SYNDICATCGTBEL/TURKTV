# TURKTV

Playlist M3U pour boitier IPTV.

## URL a entrer dans le boitier IPTV

```text
https://raw.githubusercontent.com/SYNDICATCGTBEL/TURKTV/main/turktv.m3u
```

Le boitier doit utiliser cette URL web. Si le fichier est importe en local ou par cle USB, il ne se mettra pas a jour automatiquement.

## Modifier une chaine depuis le PC

Double-cliquer sur :

```text
Modifier_Chaine_TURKTV.cmd
```

Le menu permet de :

- le lien video de la chaine ;
- l'image ou le logo de la chaine ;
- le nom affiche, si besoin.
- verifier les chaines qui ne repondent plus.
- nettoyer la playlist avec le dernier rapport de verification.
- importer les chaines absentes de `index.m3u`.
- tester une chaine avec VLC ou un lecteur HTML.

Apres la modification, le script propose de publier sur GitHub. Tant que la modification n'est pas publiee sur GitHub, le boitier IPTV ne peut pas la recuperer.

La verification cree deux fichiers locaux :

```text
chaines_a_corriger.txt
rapport_chaines.csv
```

Le nettoyage retire de `turktv.m3u` les chaines signalees en erreur et cree une sauvegarde dans `backups/`.

Le test lecteur ouvre VLC si VLC est installe sur le PC. Sinon, il cree `lecteur_turktv.html` et l'ouvre dans le navigateur.
