# GoodHabits — Tesorería de Arranque

Aplicación real con base de datos, login y tres roles (admin, captura, lectura), con auditoría automática de cada movimiento.

## Qué incluye esta carpeta

- `schema.sql` — todo lo que necesita tu base de datos: tablas, roles, permisos y triggers de auditoría.
- `index.html` — la aplicación completa (frontend). Es el único archivo que se despliega.
- `README.md` — este instructivo.

## Paso 1 — Cargar el esquema en Supabase (5 min)

1. Entra a tu proyecto de Supabase.
2. Ve a **SQL Editor** → **New query**.
3. Copia todo el contenido de `schema.sql`, pégalo y dale **Run**.
4. Debe terminar sin errores. Esto crea las tablas `profiles`, `config`, `proyecciones`, `movimientos` y `audit_log`, junto con los permisos por rol y los triggers de auditoría.

## Paso 2 — Crear tus usuarios (5 min)

La app pide **usuario + NIP** (no correo real). Por dentro, cada usuario se guarda en Supabase con un correo "de mentiras" que nunca recibe nada, con el patrón `usuario@goodhabits.local`. Tú creas ese correo sintético una sola vez por persona; ellos nunca lo ven ni lo necesitan.

1. Ve a **Authentication → Users → Add user → Create new user**.
2. Por cada persona, captura:
   - **Email**: `usuario@goodhabits.local` — reemplaza `usuario` por el nombre que esa persona va a teclear para entrar (todo minúsculas, sin espacios ni acentos). Ejemplo: si Juan va a entrar escribiendo "juan", el correo es `juan@goodhabits.local`.
   - **Password**: su NIP, de **al menos 6 dígitos** (ej. `482915`). Entre más corto el NIP, más fácil de adivinar — no bajes de 6.
   - **Auto Confirm User**: actívalo, si no la persona no podrá entrar.
3. Repite para cada persona: tú (admin), cada capturista, y quien solo consulta.
4. Anota en un lugar seguro (no en la app) la lista de usuario + NIP de cada quien, para dárselos.

**Todos entran automáticamente con rol `lectura`** — es la configuración segura por default; en el Paso 3 subes de nivel a quien corresponda.

> Nota de seguridad: un NIP de 6 dígitos es más débil que una contraseña normal. Es una decisión válida para arrancar rápido con tu equipo, pero si más adelante el sistema maneja montos grandes o más gente, vale la pena migrar a contraseñas más largas.

## Paso 3 — Asignar el rol correcto a cada quien (2 min)

1. Ve a **Table Editor → profiles**.
2. Verás una fila por cada usuario que creaste. Edita la columna `role` de cada uno:
   - tu usuario → `admin`
   - quien captura → `captura`
   - quien solo consulta → `lectura` (déjalo como está)
3. Guarda los cambios.

> Este paso —dar de alta y asignar roles— es la única parte que se hace desde el panel de Supabase, no desde la app. Es la forma más segura: nadie puede auto-asignarse como admin desde la aplicación.

## Paso 4 — Conectar el frontend a tu proyecto (2 min)

1. Ve a **Project Settings → API** en Supabase.
2. Copia el **Project URL** y la **anon public key**.
3. Abre `index.html` con cualquier editor de texto, busca cerca del inicio del `<script>`:
   ```js
   const SUPABASE_URL = 'TU_SUPABASE_URL_AQUI';
   const SUPABASE_ANON_KEY = 'TU_SUPABASE_ANON_KEY_AQUI';
   ```
4. Reemplaza ambos valores por los tuyos y guarda el archivo.

> La `anon key` es pública por diseño — no es un secreto. Toda la seguridad real vive en las políticas de la base de datos (RLS) que ya quedaron cargadas en el Paso 1.

## Paso 5 — Desplegar en Netlify (2 min)

Como ya tienes cuenta de Netlify, la forma más simple:

1. Entra a tu panel de Netlify → **Add new site → Deploy manually**.
2. Arrastra **la carpeta `goodhabits-tesoreria` completa** (no solo el `index.html`) al recuadro de despliegue — el logo de marca de agua vive en `assets/` y necesita subirse junto con la página, o no se verá.
3. Netlify te da una URL (algo como `goodhabits-tesoreria.netlify.app`). Esa es la dirección que comparten los tres usuarios.

Si prefieres conectarlo a un repositorio de Git para poder actualizarlo después con `git push`, también funciona igual — Netlify solo necesita servir el `index.html` como sitio estático, no requiere build.

## Archivos adjuntos (facturas, comprobantes)

`schema.sql` ya crea automáticamente un bucket de Storage llamado `comprobantes` con sus propios permisos (mismo criterio que la bitácora: admin y captura suben, solo admin borra, todos con perfil pueden ver). No necesitas configurar nada aparte — si corriste el Paso 1 completo, ya está listo.

- Al capturar un egreso, puedes adjuntar uno o varios archivos de cualquier tipo (PDF, foto, Excel, lo que sea).
- En la bitácora, cada movimiento con archivo muestra un enlace `📎 nombre-del-archivo`; al darle clic se abre en una pestaña nueva mediante un enlace temporal seguro (vence en 5 minutos, así que si lo compartes fuera de la app, expira rápido).
- Los archivos quedan igual de auditados que los movimientos: cada subida se registra con quién y cuándo.

**Límite a vigilar:** el plan gratuito de Supabase da 1 GB de almacenamiento de archivos en total. Para facturas y comprobantes normales (PDFs, fotos de recibo) rinde bastante, pero si empiezan a subir muchos archivos pesados (fotos en alta resolución, videos), vale la pena revisar el uso en **Project Settings → Usage**.

## Paso 6 — Probar


1. Abre la URL de Netlify.
2. Entra con el usuario **admin**: deberías ver todo, incluida la pestaña **Auditoría**.
3. Cierra sesión y entra con el usuario **captura**: puedes agregar movimientos, pero no ves la pestaña de Auditoría ni puedes borrar ni tocar el techo de inversión.
4. Cierra sesión y entra con **lectura**: ves todo, pero el formulario de captura está oculto y los campos de configuración aparecen deshabilitados.

## Qué pasa si alguien intenta hacer trampa

Aunque alguien con rol `lectura` abra las herramientas de desarrollador de su navegador e intente forzar una escritura, Supabase la rechaza en la base de datos — las políticas de seguridad (RLS) del Paso 1 no dependen del código de la página. Es la diferencia entre un candado en la puerta (esto) y un cartel que dice "no pasar" (lo que teníamos antes).

## Nota fiscal y contable

Esta herramienta es control interno / tesorería: te da trazabilidad exacta de cada egreso y quién lo capturó. No sustituye la contabilidad formal — la conciliación contra CFDI, pólizas contables y declaraciones sigue siendo trabajo de tu contador. Yo no soy contador ni puedo garantizar cumplimiento fiscal; este sistema es el insumo ordenado que le facilita ese trabajo.

## Si algo falla

- **"Tu usuario no tiene perfil asignado"** al iniciar sesión → revisa que el trigger `on_auth_user_created` se haya creado bien en el Paso 1, o crea manualmente la fila en `profiles` para ese usuario.
- **La página carga pero no aparece nada tras iniciar sesión** → revisa la consola del navegador (F12); casi siempre es la URL o la anon key mal copiadas en el Paso 4.
- **Un usuario de captura no puede guardar** → confirma en `Table Editor → profiles` que su `role` diga exactamente `captura` (sin mayúsculas ni espacios).
