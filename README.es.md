# PCScope

*Read in [English](README.md).*

### ▶ [Abrir la demo en vivo](https://davidgori.github.io/PCScope/)

La demo muestra 25 equipos ficticios y GitHub Actions la regenera cada semana.

**Inventario y revisión del estado de los ordenadores Windows de una oficina pequeña, en un minuto y sin instalar nada.**

PCScope recoge, en modo solo lectura, el inventario de cada PC: hardware, discos, Windows, seguridad, red y programas instalados. Con eso genera un único panel HTML que destaca lo que necesita atención: un disco a punto de llenarse, un portátil sin cifrar o un equipo sin antivirus o con meses sin actualizar.

![Panel de PCScope](docs/dashboard.png)

## Puntos clave

- **No hay que instalar nada:** usa PowerShell 5.1, que viene con Windows 10/11, y genera un HTML estático.
- **Solo lectura:** no cambia ninguna configuración de los equipos.
- **No necesita permisos de administrador:** cada sección se recoge por separado; si alguna no se puede leer, se avisa y se sigue con el resto.
- **Funciona sin internet:** el panel es un único archivo sin librerías externas.
- **18 reglas configurables en [`rules.json`](rules.json):** cada empresa ajusta los umbrales o desactiva comprobaciones sin tocar el código. Hay tres niveles:
  - críticos: disco por encima del 90 %, disco que falla, sin antivirus activo, 60 días sin actualizaciones, Windows 10 sin soporte;
  - advertencias: cortafuegos apagado, portátil sin BitLocker, batería gastada, administradores no previstos, programas no autorizados o desactualizados;
  - informativos: reinicio pendiente, poca RAM.
- **Vista de todos los avisos** de la oficina, con los problemas más frecuentes a un clic.
- **Buscador de software en todos los equipos:** "¿qué PC tiene todavía un Chrome antiguo?".

## Uso rápido

```powershell
git clone https://github.com/DavidGoRi/PCScope.git
cd PCScope
powershell -ExecutionPolicy Bypass -File .\PCScope.ps1 -Open
```

Para toda una oficina, ejecútalo en cada equipo con `-OutputPath \\servidor\it\pcscope -NoReport`. Después genera el panel una sola vez con `-ReportOnly -Open`.

Para probar el panel con datos ficticios:

```powershell
.\tools\New-DemoFleet.ps1 -OutputPath .\output\demo\data -Count 25
.\PCScope.ps1 -OutputPath .\output\demo -ReportOnly -Open
```

La documentación completa (parámetros, reglas, funcionamiento, privacidad, pruebas y hoja de ruta) está en el [README en inglés](README.md).

## Licencia

[MIT](LICENSE)
