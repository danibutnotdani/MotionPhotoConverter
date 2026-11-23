# Motion a Live

Convierte las Motion Photos de un teléfono Samsung en Live Photos de Apple, sin perder calidad. Funciona en iPad y Mac.

Una Motion Photo es una foto con un video corto pegado al final del archivo. Fotos de Apple solo muestra la imagen fija. Esta app separa el video y guarda el par como Live Photo, con la fecha, la ubicación y el resto de los metadatos originales.

## Cómo lo hace

- **Sin recodificar:** los bytes de la imagen se copian tal cual. Solo se reescribe el bloque Exif para agregar el identificador que une la foto con su video, así que se conserva el HDR.
- **Video intacto:** el video se pasa a MOV sin volver a comprimirlo.
- **Detección:** encuentra en tu fototeca las fotos que aún no se han convertido.
- **Reemplazo:** tras guardar la Live Photo puede borrar la original.

## Cómo compilar

Requiere Xcode 26 y [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open MotionPhotoConverter.xcodeproj
```

Cambia `DEVELOPMENT_TEAM` en `project.yml` por tu equipo de Apple. Destinos: iOS 26 y macOS 15.

`Tools/` tiene scripts sueltos para generar el ícono y comprobar en la Mac que una conversión no cambió ningún píxel.

## Limitaciones

Probada con fotos de un Galaxy S24 FE. Otros modelos pueden guardar el video de otra forma.
