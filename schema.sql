-- ============================================================
-- GoodHabits — Tesorería de Arranque
-- Esquema completo: perfiles/roles, config, movimientos, auditoría
-- Ejecutar completo en: Supabase > SQL Editor > New query > Run
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 1) PERFILES Y ROLES
-- ------------------------------------------------------------
-- Cada usuario de auth.users tiene un perfil con un rol.
-- Todo usuario nuevo entra como 'lectura' por seguridad;
-- el admin lo asciende manualmente desde Table Editor > profiles.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  role text not null default 'lectura' check (role in ('admin','captura','lectura')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Cada quien puede ver su propio perfil (para saber su rol en el frontend)
drop policy if exists "leer propio perfil" on public.profiles;
create policy "leer propio perfil"
  on public.profiles for select
  using (auth.uid() = id);

-- Crea automáticamente un perfil cuando alguien se registra
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
as $$
begin
  insert into public.profiles (id, email, role)
  values (new.id, new.email, 'lectura');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Función auxiliar: rol del usuario actual (evita repetir subconsultas)
create or replace function public.mi_rol()
returns text
language sql
stable
security definer
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- ------------------------------------------------------------
-- 2) CONFIGURACIÓN GENERAL (techo de inversión) — solo admin escribe
-- ------------------------------------------------------------
create table if not exists public.config (
  id int primary key default 1,
  monto_inicial numeric not null default 0,
  reserva_pct numeric not null default 15,
  capital_operativo numeric not null default 0,
  fase text not null default 'inversion' check (fase in ('inversion','operacion')),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);
insert into public.config (id) values (1) on conflict (id) do nothing;

alter table public.config enable row level security;

drop policy if exists "config: cualquier usuario con perfil puede leer" on public.config;
create policy "config: cualquier usuario con perfil puede leer"
  on public.config for select
  using (exists (select 1 from public.profiles where id = auth.uid()));

drop policy if exists "config: solo admin actualiza" on public.config;
create policy "config: solo admin actualiza"
  on public.config for update
  using (public.mi_rol() = 'admin');

-- ------------------------------------------------------------
-- 3) SUPUESTOS DE PROYECCIÓN (equilibrio y ventas) — admin y captura
-- ------------------------------------------------------------
create table if not exists public.proyecciones (
  id int primary key default 1,
  costos_fijos numeric not null default 0,
  costo_variable numeric not null default 0,
  precio_venta numeric not null default 0,
  venta_base numeric not null default 0,
  crecimiento_pct numeric not null default 5,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);
insert into public.proyecciones (id) values (1) on conflict (id) do nothing;

alter table public.proyecciones enable row level security;

drop policy if exists "proyecciones: cualquier usuario con perfil puede leer" on public.proyecciones;
create policy "proyecciones: cualquier usuario con perfil puede leer"
  on public.proyecciones for select
  using (exists (select 1 from public.profiles where id = auth.uid()));

drop policy if exists "proyecciones: admin y captura actualizan" on public.proyecciones;
create policy "proyecciones: admin y captura actualizan"
  on public.proyecciones for update
  using (public.mi_rol() in ('admin','captura'));

-- ------------------------------------------------------------
-- 4) BITÁCORA DE EGRESOS (movimientos) — el libro de tesorería
-- ------------------------------------------------------------
create table if not exists public.movimientos (
  id uuid primary key default gen_random_uuid(),
  fecha date not null,
  fase text not null check (fase in ('inversion','operacion')),
  rubro text not null,
  concepto text,
  proveedor text,
  forma_pago text,
  folio text,
  monto numeric not null check (monto > 0),
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.movimientos enable row level security;

-- Todos los usuarios con perfil pueden leer (admin, captura, lectura)
drop policy if exists "movimientos: cualquier usuario con perfil puede leer" on public.movimientos;
create policy "movimientos: cualquier usuario con perfil puede leer"
  on public.movimientos for select
  using (exists (select 1 from public.profiles where id = auth.uid()));

-- Solo admin y captura pueden registrar egresos
drop policy if exists "movimientos: admin y captura insertan" on public.movimientos;
create policy "movimientos: admin y captura insertan"
  on public.movimientos for insert
  with check (public.mi_rol() in ('admin','captura'));

-- El admin sí puede corregir errores de captura (los demás no).
-- Cada corrección queda registrada en la auditoría con el valor anterior y el nuevo.
drop policy if exists "movimientos: solo admin actualiza" on public.movimientos;
create policy "movimientos: solo admin actualiza"
  on public.movimientos for update
  using (public.mi_rol() = 'admin')
  with check (public.mi_rol() = 'admin');

-- Solo admin puede borrar (y el borrado queda en la auditoría)
drop policy if exists "movimientos: solo admin borra" on public.movimientos;
create policy "movimientos: solo admin borra"
  on public.movimientos for delete
  using (public.mi_rol() = 'admin');

-- ------------------------------------------------------------
-- 5) BITÁCORA DE AUDITORÍA — trazabilidad, nadie la puede alterar
-- ------------------------------------------------------------
create table if not exists public.audit_log (
  id bigserial primary key,
  table_name text not null,
  row_id uuid,
  action text not null check (action in ('INSERT','UPDATE','DELETE')),
  changed_by uuid references auth.users(id),
  changed_at timestamptz not null default now(),
  old_data jsonb,
  new_data jsonb
);

alter table public.audit_log enable row level security;

-- Solo admin puede leer la auditoría desde la app
drop policy if exists "audit_log: solo admin lee" on public.audit_log;
create policy "audit_log: solo admin lee"
  on public.audit_log for select
  using (public.mi_rol() = 'admin');

-- No se otorgan policies de insert/update/delete para el rol authenticated:
-- la única forma de escribir aquí es a través del trigger (security definer),
-- así que ni el admin puede alterar la auditoría desde la app.

create or replace function public.fn_audit_movimientos()
returns trigger
language plpgsql
security definer
as $$
begin
  if (tg_op = 'INSERT') then
    insert into public.audit_log(table_name, row_id, action, changed_by, new_data)
    values ('movimientos', new.id, 'INSERT', auth.uid(), to_jsonb(new));
    return new;
  elsif (tg_op = 'UPDATE') then
    insert into public.audit_log(table_name, row_id, action, changed_by, old_data, new_data)
    values ('movimientos', new.id, 'UPDATE', auth.uid(), to_jsonb(old), to_jsonb(new));
    return new;
  elsif (tg_op = 'DELETE') then
    insert into public.audit_log(table_name, row_id, action, changed_by, old_data)
    values ('movimientos', old.id, 'DELETE', auth.uid(), to_jsonb(old));
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_audit_movimientos on public.movimientos;
create trigger trg_audit_movimientos
  after insert or update or delete on public.movimientos
  for each row execute function public.fn_audit_movimientos();

create or replace function public.fn_audit_config()
returns trigger
language plpgsql
security definer
as $$
begin
  insert into public.audit_log(table_name, row_id, action, changed_by, old_data, new_data)
  values (tg_table_name, null, 'UPDATE', auth.uid(), to_jsonb(old), to_jsonb(new));
  new.updated_at = now();
  new.updated_by = auth.uid();
  return new;
end;
$$;

drop trigger if exists trg_audit_config on public.config;
create trigger trg_audit_config
  before update on public.config
  for each row execute function public.fn_audit_config();

drop trigger if exists trg_audit_proyecciones on public.proyecciones;
create trigger trg_audit_proyecciones
  before update on public.proyecciones
  for each row execute function public.fn_audit_config();

-- ============================================================
-- Fin del esquema. Siguiente paso: crea tus 3 usuarios desde
-- Authentication > Users, y luego ajusta su rol manualmente
-- en Table Editor > profiles (por default entran como 'lectura').
-- ============================================================

-- ------------------------------------------------------------
-- 6) ARCHIVOS ADJUNTOS (facturas, comprobantes) por movimiento
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('comprobantes', 'comprobantes', false)
on conflict (id) do nothing;

create table if not exists public.movimiento_archivos (
  id uuid primary key default gen_random_uuid(),
  movimiento_id uuid not null references public.movimientos(id) on delete cascade,
  storage_path text not null,
  nombre_original text,
  tipo_archivo text,
  subido_por uuid not null default auth.uid() references auth.users(id),
  subido_at timestamptz not null default now()
);

alter table public.movimiento_archivos enable row level security;

drop policy if exists "archivos: cualquier usuario con perfil puede leer" on public.movimiento_archivos;
create policy "archivos: cualquier usuario con perfil puede leer"
  on public.movimiento_archivos for select
  using (exists (select 1 from public.profiles where id = auth.uid()));

drop policy if exists "archivos: admin y captura suben" on public.movimiento_archivos;
create policy "archivos: admin y captura suben"
  on public.movimiento_archivos for insert
  with check (public.mi_rol() in ('admin','captura'));

drop policy if exists "archivos: solo admin borra" on public.movimiento_archivos;
create policy "archivos: solo admin borra"
  on public.movimiento_archivos for delete
  using (public.mi_rol() = 'admin');

-- Permisos sobre el propio bucket de Storage (los archivos en sí)
drop policy if exists "comprobantes: leer archivos" on storage.objects;
create policy "comprobantes: leer archivos"
  on storage.objects for select
  using (bucket_id = 'comprobantes' and exists (select 1 from public.profiles where id = auth.uid()));

drop policy if exists "comprobantes: admin y captura suben archivos" on storage.objects;
create policy "comprobantes: admin y captura suben archivos"
  on storage.objects for insert
  with check (bucket_id = 'comprobantes' and public.mi_rol() in ('admin','captura'));

drop policy if exists "comprobantes: solo admin borra archivos" on storage.objects;
create policy "comprobantes: solo admin borra archivos"
  on storage.objects for delete
  using (bucket_id = 'comprobantes' and public.mi_rol() = 'admin');

-- Auditoría también para archivos: quién adjuntó qué y cuándo
create or replace function public.fn_audit_archivos()
returns trigger
language plpgsql
security definer
as $$
begin
  if (tg_op = 'INSERT') then
    insert into public.audit_log(table_name, row_id, action, changed_by, new_data)
    values ('movimiento_archivos', new.id, 'INSERT', auth.uid(), to_jsonb(new));
    return new;
  elsif (tg_op = 'DELETE') then
    insert into public.audit_log(table_name, row_id, action, changed_by, old_data)
    values ('movimiento_archivos', old.id, 'DELETE', auth.uid(), to_jsonb(old));
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_audit_archivos on public.movimiento_archivos;
create trigger trg_audit_archivos
  after insert or delete on public.movimiento_archivos
  for each row execute function public.fn_audit_archivos();

-- ------------------------------------------------------------
-- 7) CHECKLIST DE CUMPLIMIENTO (trámites, procesos, gastos, compras)
-- ------------------------------------------------------------
create table if not exists public.pendientes (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  categoria text not null check (categoria in ('tramite','proceso','gasto','compra','otro')),
  fecha_compromiso date not null,
  fecha_cumplimiento date,
  responsable text,
  notas text,
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.pendientes enable row level security;

drop policy if exists "pendientes: cualquier usuario con perfil puede leer" on public.pendientes;
create policy "pendientes: cualquier usuario con perfil puede leer"
  on public.pendientes for select
  using (exists (select 1 from public.profiles where id = auth.uid()));

drop policy if exists "pendientes: admin y captura insertan" on public.pendientes;
create policy "pendientes: admin y captura insertan"
  on public.pendientes for insert
  with check (public.mi_rol() in ('admin','captura'));

drop policy if exists "pendientes: admin y captura actualizan" on public.pendientes;
create policy "pendientes: admin y captura actualizan"
  on public.pendientes for update
  using (public.mi_rol() in ('admin','captura'))
  with check (public.mi_rol() in ('admin','captura'));

drop policy if exists "pendientes: solo admin borra" on public.pendientes;
create policy "pendientes: solo admin borra"
  on public.pendientes for delete
  using (public.mi_rol() = 'admin');

create or replace function public.fn_audit_pendientes()
returns trigger
language plpgsql
security definer
as $$
begin
  if (tg_op = 'INSERT') then
    insert into public.audit_log(table_name, row_id, action, changed_by, new_data)
    values ('pendientes', new.id, 'INSERT', auth.uid(), to_jsonb(new));
    return new;
  elsif (tg_op = 'UPDATE') then
    new.updated_at = now();
    insert into public.audit_log(table_name, row_id, action, changed_by, old_data, new_data)
    values ('pendientes', new.id, 'UPDATE', auth.uid(), to_jsonb(old), to_jsonb(new));
    return new;
  elsif (tg_op = 'DELETE') then
    insert into public.audit_log(table_name, row_id, action, changed_by, old_data)
    values ('pendientes', old.id, 'DELETE', auth.uid(), to_jsonb(old));
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_audit_pendientes on public.pendientes;
create trigger trg_audit_pendientes
  before insert or update or delete on public.pendientes
  for each row execute function public.fn_audit_pendientes();
