-- =====================================================================
-- Crystal Loans · Callender — database trên Supabase (bản 3: mỗi chức năng một bảng)
-- Chạy trong Supabase → SQL Editor → New query → dán toàn bộ → Run.
-- Chạy lại nhiều lần cũng không sao. Bản 1, bản 2 cũ được dọn hoặc chuyển dữ liệu sang tự động.
--
-- Nguyên tắc
--   · Mọi dữ liệu là của riêng từng tài khoản (cột owner_id). Không ai đọc hay sửa được dữ liệu người khác.
--   · App chỉ đọc ghi qua các hàm load_docs / save_doc / save_docs / delete_doc: mỗi lần lưu là một
--     giao dịch trọn vẹn (ca làm cùng người làm và từng việc lưu một lần, không bao giờ lưu dở).
--   · Riêng lịch: ai mở trang, đăng nhập hay không, đều xem được các ca mọi người đã đặt qua hàm
--     public_calendar; mỗi người tự chọn ca của mình hiện bao nhiêu chi tiết (bảng public_settings).
--   · Trường nào app có mà bảng chưa có cột riêng thì nằm trong cột extra, nên không mất dữ liệu.
--
-- Bảng (trong ngoặc là phần tương ứng trong app)
--   profiles                 tài khoản, vai trò, trạng thái, cài đặt cá nhân (Thiết lập → Tài khoản)
--
-- Vai trò: tài khoản mới luôn là member. Admin chỉ đặt trong Supabase (app không đổi được), ví dụ:
--   update public.profiles set role = 'admin' where email = 'ten@congty.com';
--   companies                công ty và hệ số lương (Thiết lập → Công ty)
--   people                   người làm (Thiết lập → Người làm)
--   clients                  khách hàng trên lịch
--   holidays                 ngày lễ: hằng năm dương lịch, âm lịch, hoặc một ngày (Thiết lập → Ngày lễ)
--   tasks                    ca làm trên lịch (Lịch, Công việc, Kỳ tính lương)
--     task_workers           người làm trong ca
--     task_items             từng việc của mỗi người, kèm khách hàng và đã xong hay chưa
--   loan_cases               hồ sơ khách (Client's Profile, Master Data)
--     loan_case_people       người vay, người bảo lãnh… trong hồ sơ
--     loan_case_values       giá trị đã nhập: chung cả hồ sơ (slot_id = '') hoặc riêng từng người
--     loan_case_documents    chứng từ đã nhận
--   loan_rules               dòng trong bảng Rules
--     loan_rule_conditions   điều kiện của từng dòng
--   loan_fields              ô nhập liệu (cột điều kiện) của form hồ sơ
--   loan_stages              tên giai đoạn
--   loan_slots               người trong form hồ sơ và giá trị "Áp dụng cho" họ nhận
--   loan_sheet               bố cục bảng Rules: tên cột, thứ tự, màu, chữ đậm, cột đã xoá
--   glossary                 thuật ngữ
--   public_settings          mỗi người chọn ca của mình hiện gì trên lịch chung
-- =====================================================================

-- ---------- 0. Dọn bản cũ ----------
do $$ begin
  -- bản 1 (app_docs dùng chung, không có owner_id): chỉ bỏ khi còn trống
  if to_regclass('public.app_docs') is not null
     and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'app_docs' and column_name = 'owner_id') then
    if exists (select 1 from public.app_docs) then
      raise exception 'Bảng app_docs bản 1 đã có dữ liệu: cần chuyển tay trước khi nâng cấp';
    end if;
    drop table public.app_docs cascade;
  end if;
  -- bản 1 của public_settings là một bộ cài đặt chung: thay bằng cài đặt riêng từng người
  if to_regclass('public.public_settings') is not null
     and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'public_settings' and column_name = 'owner_id') then
    drop table public.public_settings cascade;
  end if;
end $$;
drop function if exists public.is_staff() cascade;
drop function if exists public.public_glossary();
drop function if exists public.public_calendar(date, date);

-- ---------- 1. Tài khoản ----------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text not null default '',
  display_name text not null default '',
  role         text not null default 'member' check (role in ('admin', 'member')),
  status       text not null default 'active' check (status in ('pending', 'active', 'disabled')),
  person_id    text,                                   -- người làm ứng với tài khoản ("Ngày của tôi")
  prefs        jsonb not null default '{}'::jsonb,     -- ngôn ngữ, giao diện, kiểu xem lịch, kỳ lương
  created_at   timestamptz not null default now()
);
alter table public.profiles add column if not exists prefs jsonb not null default '{}'::jsonb;
-- bản cũ gọi vai trò thường là staff: đổi thành member
alter table public.profiles drop constraint if exists profiles_role_check;
update public.profiles set role = 'member' where role not in ('admin', 'member');
alter table public.profiles alter column role set default 'member';
alter table public.profiles add constraint profiles_role_check check (role in ('admin', 'member'));
alter table public.profiles alter column status set default 'active';
update public.profiles set status = 'active' where status = 'pending';
alter table public.profiles enable row level security;

create or replace function public.is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and status = 'active');
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and status = 'active' and role = 'admin');
$$;

-- Tài khoản mới tự có dòng profiles, luôn là member. Admin chỉ đặt trong Supabase.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, email, display_name, role, status)
  values (new.id, coalesce(new.email, ''),
          left(coalesce(nullif(new.raw_user_meta_data->>'display_name', ''), split_part(coalesce(new.email, ''), '@', 1)), 80),
          'member', 'active')
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

drop policy if exists "profiles: read own or admin" on public.profiles;
create policy "profiles: read own or admin" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());
revoke insert, update, delete on public.profiles from authenticated, anon;
grant update (display_name, person_id, prefs) on public.profiles to authenticated;
drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Admin khoá / mở khoá tài khoản trong app. Vai trò thì không đổi được ở đây (chỉ trong Supabase).
drop function if exists public.admin_set_member(uuid, text, text, text);
create or replace function public.admin_set_status(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Chỉ admin mới khoá hoặc mở khoá được tài khoản' using errcode = '42501'; end if;
  if p_status not in ('active', 'disabled') then raise exception 'Giá trị không hợp lệ' using errcode = '22023'; end if;
  if p_id = auth.uid() and p_status <> 'active' then
    raise exception 'Không thể tự khoá tài khoản của mình' using errcode = '42501';
  end if;
  update profiles set status = p_status where id = p_id;
end $$;

-- Mỗi tài khoản là một người làm: người đã đăng nhập xem được danh sách tên các tài khoản đang dùng
-- để thêm họ vào ca. Chỉ trả mã và tên hiển thị, không trả email.
create or replace function public.list_workers() returns table (id uuid, display_name text)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(nullif(p.display_name, ''), split_part(p.email, '@', 1))
  from profiles p where p.status = 'active' and public.is_active()
  order by 2;
$$;

-- ---------- 2. Hàm đổi kiểu an toàn (giá trị lạ thì thành null, không làm hỏng cả lần lưu) ----------
create or replace function public._txt(v jsonb) returns text language sql immutable as $$
  select case when jsonb_typeof(v) in ('string', 'number', 'boolean') then v #>> '{}' end $$;
create or replace function public._num(v jsonb) returns numeric language sql immutable as $$
  select case when jsonb_typeof(v) = 'number' then (v #>> '{}')::numeric
              when jsonb_typeof(v) = 'string' and (v #>> '{}') ~ '^-?\d+(\.\d+)?$' then (v #>> '{}')::numeric end $$;
create or replace function public._int(v jsonb) returns integer language sql immutable as $$
  select round(public._num(v))::integer $$;
create or replace function public._bool(v jsonb) returns boolean language sql immutable as $$
  select case when jsonb_typeof(v) = 'boolean' then (v #>> '{}')::boolean
              when jsonb_typeof(v) = 'number' then (v #>> '{}')::numeric <> 0 end $$;
create or replace function public._date(v jsonb) returns date language plpgsql immutable as $$
begin
  if jsonb_typeof(v) = 'string' and (v #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$' then return (v #>> '{}')::date; end if;
  return null;
exception when others then return null;
end $$;
create or replace function public._time(v jsonb) returns time language plpgsql immutable as $$
begin
  if jsonb_typeof(v) = 'string' and (v #>> '{}') ~ '^\d{1,2}:\d{2}(:\d{2})?$' then return (v #>> '{}')::time; end if;
  return null;
exception when others then return null;
end $$;
create or replace function public._ts(v jsonb) returns timestamptz language plpgsql immutable as $$
begin
  if jsonb_typeof(v) = 'string' and v #>> '{}' <> '' then return (v #>> '{}')::timestamptz; end if;
  return null;
exception when others then return null;
end $$;
create or replace function public._iso(t timestamptz) returns text language sql immutable as $$
  select to_char(t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') $$;
create or replace function public._arr(v jsonb) returns jsonb language sql immutable as $$
  select case when jsonb_typeof(v) = 'array' then v else '[]'::jsonb end $$;
create or replace function public._obj(v jsonb) returns jsonb language sql immutable as $$
  select case when jsonb_typeof(v) = 'object' then v else '{}'::jsonb end $$;
create or replace function public._texts(v jsonb) returns text[] language sql immutable as $$
  select coalesce(array(select e #>> '{}' from jsonb_array_elements(public._arr(v)) e where jsonb_typeof(e) <> 'null'), '{}') $$;

-- ---------- 3. Bảng ----------
create table if not exists public.companies (
  owner_id  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id        text not null check (length(id) between 1 and 100),
  name      text not null default '',
  mode      text not null default 'hour' check (mode in ('hour', 'day', 'fixed')),   -- theo giờ, theo ngày công, cố định tháng
  rate      numeric not null default 0,                                              -- đơn giá
  ot        numeric,            -- hệ số tăng ca ngày thường
  hpd       numeric,            -- giờ chuẩn mỗi ngày
  color     text,
  ot_week   numeric,            -- hệ số ngày nghỉ tuần
  ot_hol    numeric,            -- hệ số ngày lễ
  ot_leave  numeric,            -- hệ số nghỉ có lương
  ot_night  numeric,            -- phụ cấp giờ đêm (cộng thêm)
  extra     jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (owner_id, id)
);
create table if not exists public.people (
  owner_id  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id        text not null check (length(id) between 1 and 100),
  name      text not null default '',
  color     text,
  extra     jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (owner_id, id)
);
create table if not exists public.clients (
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id         text not null check (length(id) between 1 and 100),
  name       text not null default '',
  company_id text,              -- companies.id (để trống được)
  case_id    text,              -- loan_cases.id: hồ sơ vay của khách này
  extra      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (owner_id, id)
);
create table if not exists public.holidays (
  owner_id  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id        text not null check (length(id) between 1 and 100),
  name      text not null default '',
  md        text check (md ~ '^\d{2}-\d{2}$'),      -- hằng năm, dương lịch: "MM-DD"
  lunar     text check (lunar ~ '^\d{2}-\d{2}$'),   -- hằng năm, âm lịch: "MM-DD"
  on_date   date,                                   -- một ngày cụ thể
  span      integer,                                -- số ngày nghỉ liên tiếp
  pre       integer,                                -- nghỉ sớm hơn mấy ngày (Tết)
  extra     jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (owner_id, id)
);
create table if not exists public.tasks (
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id         text not null check (length(id) between 1 and 100),
  work_date  date,
  start_time time,
  end_time   time,              -- nhỏ hơn hoặc bằng giờ bắt đầu nghĩa là ca qua đêm
  company_id text,
  overtime   boolean not null default false,
  note       text,              -- ghi chú tăng ca
  day_type   text check (day_type in ('normal', 'weekend', 'holiday', 'leave')),   -- trống: tự nhận theo lịch
  done       boolean not null default false,
  extra      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (owner_id, id)
);
create index if not exists tasks_date on public.tasks (work_date);
create table if not exists public.task_workers (
  owner_id   uuid not null,
  task_id    text not null,
  position   integer not null,
  id         text not null,
  person_id  text not null default '',
  primary key (owner_id, task_id, position),
  foreign key (owner_id, task_id) references public.tasks (owner_id, id) on delete cascade
);
create table if not exists public.task_items (
  owner_id   uuid not null,
  task_id    text not null,
  worker_pos integer not null,
  position   integer not null,
  id         text not null,
  text       text not null default '',
  client_id  text not null default '',
  done       boolean not null default false,
  primary key (owner_id, task_id, worker_pos, position),
  foreign key (owner_id, task_id, worker_pos) references public.task_workers (owner_id, task_id, position) on delete cascade
);
create index if not exists task_items_client on public.task_items (owner_id, client_id);
create table if not exists public.loan_cases (
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id         text not null check (length(id) between 1 and 100),
  client_id  text,              -- clients.id; '' là đã chọn "không gắn khách"
  created_at timestamptz,
  extra      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (owner_id, id)
);
create table if not exists public.loan_case_people (
  owner_id   uuid not null,
  case_id    text not null,
  slot_id    text not null check (slot_id <> ''),   -- loan_slots.id: Người vay 1, Người bảo lãnh 1…
  name       text not null default '',
  primary key (owner_id, case_id, slot_id),
  foreign key (owner_id, case_id) references public.loan_cases (owner_id, id) on delete cascade
);
create table if not exists public.loan_case_values (
  owner_id   uuid not null,
  case_id    text not null,
  slot_id    text not null default '',              -- '' = thông tin chung của hồ sơ
  field_id   text not null,                         -- loan_fields.id
  value      jsonb,                                 -- chữ, số, có/không, hoặc danh sách lựa chọn
  primary key (owner_id, case_id, slot_id, field_id),
  foreign key (owner_id, case_id) references public.loan_cases (owner_id, id) on delete cascade
);
create table if not exists public.loan_case_documents (
  owner_id    uuid not null,
  case_id     text not null,
  doc_key     text not null,                        -- nhóm|giai đoạn|tên chứng từ
  received_at timestamptz not null default now(),
  primary key (owner_id, case_id, doc_key),
  foreign key (owner_id, case_id) references public.loan_cases (owner_id, id) on delete cascade
);
create table if not exists public.loan_rules (
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id         text not null check (length(id) between 1 and 100),
  doc        text not null default '',              -- tên chứng từ
  link       text not null default '',              -- link mẫu
  bold       boolean not null default false,
  stage      integer,                               -- giai đoạn
  applies_to text not null default '',              -- áp dụng cho; trống = hồ sơ chung
  match_mode text not null default 'all' check (match_mode in ('all', 'any')),
  position   numeric,                               -- thứ tự dòng
  extra      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (owner_id, id)
);
create table if not exists public.loan_rule_conditions (
  owner_id   uuid not null,
  rule_id    text not null,
  position   integer not null,
  field_id   text not null default '',
  op         text not null default '',              -- is, not, in, has, lacks, hasAny, gte, between, contains…
  value      jsonb,
  primary key (owner_id, rule_id, position),
  foreign key (owner_id, rule_id) references public.loan_rules (owner_id, id) on delete cascade
);
create table if not exists public.loan_fields (
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  position   integer not null,
  id         text not null,
  label      text not null default '',
  type       text not null default 'one' check (type in ('one', 'many', 'number', 'text', 'bool')),
  scope      text not null default 'case' check (scope in ('case', 'person')),
  unit       text,
  options    text[] not null default '{}',
  extra      jsonb not null default '{}'::jsonb,
  primary key (owner_id, position)
);
create table if not exists public.loan_stages (
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  position   integer not null,                      -- giai đoạn thứ mấy (từ 1)
  name       text not null default '',
  primary key (owner_id, position)
);
create table if not exists public.loan_slots (
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  position   integer not null,
  id         text not null,
  label      text not null default '',
  applies_to text[] not null default '{}',          -- giá trị "Áp dụng cho" người này nhận
  extra      jsonb not null default '{}'::jsonb,
  primary key (owner_id, position)
);
create table if not exists public.loan_sheet (
  owner_id     uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  col_names    jsonb,       -- tên cột vai trò: chứng từ, giai đoạn, áp dụng cho
  col_order    text[],      -- thứ tự cột (null: thứ tự mặc định)
  removed      text[],      -- cột vai trò đã xoá (null: theo mặc định)
  removed_at   jsonb,       -- thứ tự cột lúc xoá, để thêm lại đúng chỗ
  trash        jsonb,       -- cột điều kiện đã xoá, để khôi phục
  value_colors jsonb,       -- màu theo giá trị của từng cột
  col_bold     jsonb,       -- cột in đậm
  stage_colors jsonb,       -- màu giai đoạn kiểu cũ
  has_slots    boolean not null default false,   -- đã từng lưu danh sách người trong form
  extra        jsonb not null default '{}'::jsonb,
  updated_at   timestamptz not null default now()
);
create table if not exists public.glossary (
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id         text not null check (length(id) between 1 and 100),
  term       text not null default '',
  body       text not null default '',
  created_at timestamptz,
  extra      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (owner_id, id)
);
-- key: calendar.busy (hiện khung giờ), calendar.company, calendar.people, calendar.clients, calendar.tasks.
-- Chưa có dòng nào thì dùng mặc định: hiện khung giờ, giấu mọi chi tiết khác.
create table if not exists public.public_settings (
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  key        text not null check (key in ('calendar.busy', 'calendar.company', 'calendar.people', 'calendar.clients', 'calendar.tasks')),
  is_public  boolean not null,
  updated_at timestamptz not null default now(),
  primary key (owner_id, key)
);

-- ---------- 4. Quyền: mỗi người chỉ đọc dữ liệu của mình; ghi qua các hàm ở mục 5 ----------
do $$
declare t text;
begin
  foreach t in array array['companies', 'people', 'clients', 'holidays', 'tasks', 'task_workers', 'task_items',
    'loan_cases', 'loan_case_people', 'loan_case_values', 'loan_case_documents', 'loan_rules', 'loan_rule_conditions',
    'loan_fields', 'loan_stages', 'loan_slots', 'loan_sheet', 'glossary'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "own read" on public.%I', t);
    execute format('create policy "own read" on public.%I for select to authenticated using (owner_id = auth.uid() and public.is_active())', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
    -- thay đổi hiện ngay trên máy khác của cùng tài khoản
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
alter table public.public_settings enable row level security;
drop policy if exists "public_settings: own" on public.public_settings;
create policy "public_settings: own" on public.public_settings for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
revoke all on public.public_settings from anon;

-- ---------- 5. Đọc ghi dữ liệu app ----------
-- Một bản ghi của app (JSON) → các bảng. Gọi nội bộ, người dùng không gọi trực tiếp được.
create or replace function public._save_doc(o uuid, c text, i text, d jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare r record; crew jsonb; items jsonb; txt text;
begin
  if o is null then raise exception 'Chưa đăng nhập' using errcode = '42501'; end if;
  if i is null or length(i) not between 1 and 100 then raise exception 'Mã bản ghi không hợp lệ' using errcode = '22023'; end if;
  d := _obj(d) - 'id';
  case c
  when 'companies' then
    delete from companies where owner_id = o and id = i;
    insert into companies (owner_id, id, name, mode, rate, ot, hpd, color, ot_week, ot_hol, ot_leave, ot_night, extra)
    values (o, i, coalesce(_txt(d->'name'), ''), case when d->>'mode' in ('hour', 'day', 'fixed') then d->>'mode' else 'hour' end,
      coalesce(_num(d->'rate'), 0), _num(d->'ot'), _num(d->'hpd'), _txt(d->'color'),
      _num(d->'otWeek'), _num(d->'otHol'), _num(d->'otLeave'), _num(d->'otNight'),
      d - array['name', 'mode', 'rate', 'ot', 'hpd', 'color', 'otWeek', 'otHol', 'otLeave', 'otNight']);
  when 'people' then
    delete from people where owner_id = o and id = i;
    insert into people (owner_id, id, name, color, extra)
    values (o, i, coalesce(_txt(d->'name'), ''), _txt(d->'color'), d - array['name', 'color']);
  when 'clients' then
    delete from clients where owner_id = o and id = i;
    insert into clients (owner_id, id, name, company_id, case_id, extra)
    values (o, i, coalesce(_txt(d->'name'), ''), _txt(d->'companyId'), _txt(d->'caseId'), d - array['name', 'companyId', 'caseId']);
  when 'holidays' then
    delete from holidays where owner_id = o and id = i;
    insert into holidays (owner_id, id, name, md, lunar, on_date, span, pre, extra)
    values (o, i, coalesce(_txt(d->'name'), ''),
      case when d->>'md' ~ '^\d{2}-\d{2}$' then d->>'md' end, case when d->>'lunar' ~ '^\d{2}-\d{2}$' then d->>'lunar' end,
      _date(d->'date'), _int(d->'span'), _int(d->'pre'), d - array['name', 'md', 'lunar', 'date', 'span', 'pre']);
  when 'tasks' then
    -- ca kiểu cũ (không có crew): người làm và danh sách việc cũ thành người làm đầu tiên
    if jsonb_typeof(d->'crew') = 'array' and jsonb_array_length(d->'crew') > 0 then crew := d->'crew';
    else
      items := _arr(d->'items');
      if jsonb_array_length(items) = 0 then
        txt := concat_ws(' — ', nullif(nullif(trim(coalesce(d->>'title', '')), ''), 'Nhiệm vụ'), nullif(trim(coalesce(d->>'desc', '')), ''));
        if coalesce(txt, '') <> '' or coalesce(d->>'clientId', '') <> '' then
          items := jsonb_build_array(jsonb_build_object('id', 'i0', 'text', coalesce(nullif(txt, ''), 'Việc'), 'clientId', coalesce(d->>'clientId', ''), 'done', coalesce(_bool(d->'done'), false)));
        end if;
      end if;
      crew := jsonb_build_array(jsonb_build_object('id', 'w0', 'personId', coalesce(d->>'personId', ''), 'items', items));
    end if;
    delete from tasks where owner_id = o and id = i;
    insert into tasks (owner_id, id, work_date, start_time, end_time, company_id, overtime, note, day_type, done, extra)
    values (o, i, _date(d->'date'), _time(d->'start'), _time(d->'end'), _txt(d->'companyId'), coalesce(_bool(d->'overtime'), false),
      _txt(d->'note'), case when d->>'dayType' in ('normal', 'weekend', 'holiday', 'leave') then d->>'dayType' end, coalesce(_bool(d->'done'), false),
      -- items, title, personId, clientId, desc là bản chép lại từ crew: dựng lại khi đọc
      d - array['date', 'start', 'end', 'companyId', 'overtime', 'note', 'dayType', 'done', 'crew', 'items', 'title', 'personId', 'clientId', 'desc']);
    for r in select e.value as w, e.ordinality::int as pos from jsonb_array_elements(crew) with ordinality e loop
      insert into task_workers (owner_id, task_id, position, id, person_id)
      values (o, i, r.pos, coalesce(_txt(r.w->'id'), 'w' || r.pos), coalesce(_txt(r.w->'personId'), ''));
      insert into task_items (owner_id, task_id, worker_pos, position, id, text, client_id, done)
      select o, i, r.pos, e.ordinality::int, coalesce(_txt(e.value->'id'), 'i' || e.ordinality), coalesce(_txt(e.value->'text'), ''),
        coalesce(_txt(e.value->'clientId'), ''), coalesce(_bool(e.value->'done'), false)
      from jsonb_array_elements(_arr(r.w->'items')) with ordinality e;
    end loop;
  when 'loanCases' then
    delete from loan_cases where owner_id = o and id = i;
    insert into loan_cases (owner_id, id, client_id, created_at, extra)
    values (o, i, _txt(d->'clientId'), _ts(d->'createdAt'), d - array['clientId', 'createdAt', 'values', 'received', 'people']);
    insert into loan_case_values (owner_id, case_id, slot_id, field_id, value)
    select o, i, '', e.key, e.value from jsonb_each(_obj(d->'values')) e;
    for r in select e.key as slot, e.value as p from jsonb_each(_obj(d->'people')) e where e.key <> '' loop
      insert into loan_case_people (owner_id, case_id, slot_id, name) values (o, i, r.slot, coalesce(_txt(r.p->'name'), ''));
      insert into loan_case_values (owner_id, case_id, slot_id, field_id, value)
      select o, i, r.slot, e.key, e.value from jsonb_each(_obj(r.p->'values')) e;
    end loop;
    insert into loan_case_documents (owner_id, case_id, doc_key)
    select o, i, e.key from jsonb_each(_obj(d->'received')) e where e.value = 'true'::jsonb;
  when 'loanRules' then
    delete from loan_rules where owner_id = o and id = i;
    insert into loan_rules (owner_id, id, doc, link, bold, stage, applies_to, match_mode, position, extra)
    values (o, i, coalesce(_txt(d->'doc'), ''), coalesce(_txt(d->'link'), ''), coalesce(_bool(d->'bold'), false), _int(d->'stage'),
      coalesce(_txt(d->'appliesTo'), ''), case when d->>'match' = 'any' then 'any' else 'all' end, _num(d->'order'),
      d - array['doc', 'link', 'bold', 'stage', 'appliesTo', 'match', 'order', 'conds']);
    insert into loan_rule_conditions (owner_id, rule_id, position, field_id, op, value)
    select o, i, e.ordinality::int, coalesce(_txt(e.value->'field'), ''), coalesce(_txt(e.value->'op'), ''), e.value->'value'
    from jsonb_array_elements(_arr(d->'conds')) with ordinality e;
  when 'loanConfig' then
    if i <> 'lists' then raise exception 'Cấu hình chỉ có một bản ghi tên lists' using errcode = '22023'; end if;
    delete from loan_sheet where owner_id = o;
    delete from loan_fields where owner_id = o;
    delete from loan_stages where owner_id = o;
    delete from loan_slots where owner_id = o;
    insert into loan_sheet (owner_id, col_names, col_order, removed, removed_at, trash, value_colors, col_bold, stage_colors, has_slots, extra)
    values (o, d->'colNames', case when jsonb_typeof(d->'colOrder') = 'array' then _texts(d->'colOrder') end,
      case when jsonb_typeof(d->'removed') = 'array' then _texts(d->'removed') end,
      d->'removedAt', d->'trash', d->'valueColors', d->'colBold', d->'stageColors', jsonb_typeof(d->'slots') = 'array',
      d - array['fields', 'stages', 'slots', 'colNames', 'colOrder', 'removed', 'removedAt', 'trash', 'valueColors', 'colBold', 'stageColors']);
    insert into loan_fields (owner_id, position, id, label, type, scope, unit, options, extra)
    select o, e.ordinality::int, coalesce(_txt(e.value->'id'), 'f' || e.ordinality), coalesce(_txt(e.value->'label'), ''),
      case when e.value->>'type' in ('one', 'many', 'number', 'text', 'bool') then e.value->>'type' else 'one' end,
      case when e.value->>'scope' = 'person' then 'person' else 'case' end, _txt(e.value->'unit'), _texts(e.value->'options'),
      _obj(e.value) - array['id', 'label', 'type', 'scope', 'unit', 'options']
    from jsonb_array_elements(_arr(d->'fields')) with ordinality e;
    insert into loan_stages (owner_id, position, name)
    select o, e.ordinality::int, coalesce(e.value #>> '{}', '') from jsonb_array_elements(_arr(d->'stages')) with ordinality e;
    insert into loan_slots (owner_id, position, id, label, applies_to, extra)
    select o, e.ordinality::int, coalesce(_txt(e.value->'id'), 's' || e.ordinality), coalesce(_txt(e.value->'label'), ''), _texts(e.value->'who'),
      _obj(e.value) - array['id', 'label', 'who']
    from jsonb_array_elements(_arr(d->'slots')) with ordinality e;
  when 'glossary' then
    delete from glossary where owner_id = o and id = i;
    insert into glossary (owner_id, id, term, body, created_at, extra)
    values (o, i, coalesce(_txt(d->'term'), ''), coalesce(_txt(d->'body'), ''), _ts(d->'createdAt'), d - array['term', 'body', 'createdAt']);
  else
    raise exception 'Không có loại dữ liệu %', c using errcode = '22023';
  end case;
end $$;

create or replace function public._delete_doc(o uuid, c text, i text) returns void
language plpgsql security definer set search_path = public as $$
begin
  case c
  when 'companies' then delete from companies where owner_id = o and id = i;
  when 'people'    then delete from people    where owner_id = o and id = i;
  when 'clients'   then delete from clients   where owner_id = o and id = i;
  when 'holidays'  then delete from holidays  where owner_id = o and id = i;
  when 'tasks'     then delete from tasks     where owner_id = o and id = i;
  when 'loanCases' then delete from loan_cases where owner_id = o and id = i;
  when 'loanRules' then delete from loan_rules where owner_id = o and id = i;
  when 'glossary'  then delete from glossary  where owner_id = o and id = i;
  when 'loanConfig' then
    delete from loan_sheet where owner_id = o; delete from loan_fields where owner_id = o;
    delete from loan_stages where owner_id = o; delete from loan_slots where owner_id = o;
  else raise exception 'Không có loại dữ liệu %', c using errcode = '22023';
  end case;
end $$;

-- Các bảng → đúng dạng JSON app đang dùng, gom theo loại.
create or replace function public._load_docs(o uuid, cs text[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare res jsonb := '{}'::jsonb;
  want text[] := coalesce(cs, array['companies', 'people', 'clients', 'holidays', 'tasks', 'loanCases', 'loanRules', 'loanConfig', 'glossary']);
begin
  if 'companies' = any(want) then
    res := res || jsonb_build_object('companies', coalesce((select jsonb_agg(x.extra || jsonb_strip_nulls(jsonb_build_object(
      'id', x.id, 'name', x.name, 'mode', x.mode, 'rate', x.rate, 'ot', x.ot, 'hpd', x.hpd, 'color', x.color,
      'otWeek', x.ot_week, 'otHol', x.ot_hol, 'otLeave', x.ot_leave, 'otNight', x.ot_night)) order by x.id)
      from companies x where x.owner_id = o), '[]'::jsonb));
  end if;
  if 'people' = any(want) then
    res := res || jsonb_build_object('people', coalesce((select jsonb_agg(x.extra || jsonb_strip_nulls(jsonb_build_object(
      'id', x.id, 'name', x.name, 'color', x.color)) order by x.id) from people x where x.owner_id = o), '[]'::jsonb));
  end if;
  if 'clients' = any(want) then
    res := res || jsonb_build_object('clients', coalesce((select jsonb_agg(x.extra || jsonb_strip_nulls(jsonb_build_object(
      'id', x.id, 'name', x.name, 'companyId', x.company_id, 'caseId', x.case_id)) order by x.id) from clients x where x.owner_id = o), '[]'::jsonb));
  end if;
  if 'holidays' = any(want) then
    res := res || jsonb_build_object('holidays', coalesce((select jsonb_agg(x.extra || jsonb_strip_nulls(jsonb_build_object(
      'id', x.id, 'name', x.name, 'md', x.md, 'lunar', x.lunar, 'date', to_char(x.on_date, 'YYYY-MM-DD'), 'span', x.span, 'pre', x.pre)) order by x.id)
      from holidays x where x.owner_id = o), '[]'::jsonb));
  end if;
  if 'tasks' = any(want) then
    res := res || jsonb_build_object('tasks', coalesce((select jsonb_agg(t.extra || jsonb_strip_nulls(jsonb_build_object(
      'id', t.id, 'date', to_char(t.work_date, 'YYYY-MM-DD'), 'start', left(t.start_time::text, 5), 'end', left(t.end_time::text, 5),
      'companyId', t.company_id, 'overtime', t.overtime, 'note', t.note, 'dayType', t.day_type, 'done', t.done))
      || jsonb_build_object('crew', cr.crew, 'items', coalesce(cr.crew->0->'items', '[]'::jsonb), 'personId', coalesce(cr.crew->0->>'personId', ''),
        'title', coalesce(fi.text, ''), 'clientId', coalesce(fi.client_id, ''), 'desc', '') order by t.work_date, t.start_time, t.id)
      from tasks t
      cross join lateral (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'personId', w.person_id, 'items',
          (select coalesce(jsonb_agg(jsonb_build_object('id', it.id, 'text', it.text, 'clientId', it.client_id, 'done', it.done) order by it.position), '[]'::jsonb)
           from task_items it where it.owner_id = w.owner_id and it.task_id = w.task_id and it.worker_pos = w.position)) order by w.position), '[]'::jsonb) as crew
        from task_workers w where w.owner_id = t.owner_id and w.task_id = t.id) cr
      left join lateral (select it.text, it.client_id from task_items it where it.owner_id = t.owner_id and it.task_id = t.id
        order by it.worker_pos, it.position limit 1) fi on true
      where t.owner_id = o), '[]'::jsonb));
  end if;
  if 'loanCases' = any(want) then
    res := res || jsonb_build_object('loanCases', coalesce((select jsonb_agg(k.extra || jsonb_strip_nulls(jsonb_build_object(
        'id', k.id, 'clientId', k.client_id, 'createdAt', _iso(k.created_at)))
      || jsonb_build_object(
        'values', coalesce((select jsonb_object_agg(v.field_id, v.value) from loan_case_values v
          where v.owner_id = k.owner_id and v.case_id = k.id and v.slot_id = ''), '{}'::jsonb),
        'received', coalesce((select jsonb_object_agg(dd.doc_key, true) from loan_case_documents dd
          where dd.owner_id = k.owner_id and dd.case_id = k.id), '{}'::jsonb),
        'people', coalesce((select jsonb_object_agg(p.slot_id, jsonb_build_object('name', p.name, 'values',
            coalesce((select jsonb_object_agg(v.field_id, v.value) from loan_case_values v
              where v.owner_id = p.owner_id and v.case_id = p.case_id and v.slot_id = p.slot_id), '{}'::jsonb)))
          from loan_case_people p where p.owner_id = k.owner_id and p.case_id = k.id), '{}'::jsonb)) order by k.created_at nulls first, k.id)
      from loan_cases k where k.owner_id = o), '[]'::jsonb));
  end if;
  if 'loanRules' = any(want) then
    res := res || jsonb_build_object('loanRules', coalesce((select jsonb_agg(r.extra || jsonb_strip_nulls(jsonb_build_object(
        'id', r.id, 'doc', r.doc, 'link', r.link, 'bold', r.bold, 'stage', r.stage, 'appliesTo', r.applies_to, 'match', r.match_mode, 'order', r.position))
      || jsonb_build_object('conds', coalesce((select jsonb_agg(jsonb_build_object('field', cd.field_id, 'op', cd.op, 'value', cd.value) order by cd.position)
        from loan_rule_conditions cd where cd.owner_id = r.owner_id and cd.rule_id = r.id), '[]'::jsonb)) order by r.position nulls last, r.id)
      from loan_rules r where r.owner_id = o), '[]'::jsonb));
  end if;
  if 'loanConfig' = any(want) then
    res := res || jsonb_build_object('loanConfig', coalesce((select jsonb_agg(s.extra || jsonb_build_object('id', 'lists',
        'fields', coalesce((select jsonb_agg(f.extra || jsonb_strip_nulls(jsonb_build_object('id', f.id, 'label', f.label, 'type', f.type,
          'scope', f.scope, 'unit', f.unit)) || jsonb_build_object('options', to_jsonb(f.options)) order by f.position)
          from loan_fields f where f.owner_id = s.owner_id), '[]'::jsonb),
        'stages', coalesce((select jsonb_agg(st.name order by st.position) from loan_stages st where st.owner_id = s.owner_id), '[]'::jsonb))
      || case when s.has_slots then jsonb_build_object('slots', coalesce((select jsonb_agg(sl.extra || jsonb_build_object('id', sl.id, 'label', sl.label,
          'who', to_jsonb(sl.applies_to)) order by sl.position) from loan_slots sl where sl.owner_id = s.owner_id), '[]'::jsonb)) else '{}'::jsonb end
      || case when s.col_names    is not null then jsonb_build_object('colNames', s.col_names)       else '{}'::jsonb end
      || case when s.col_order    is not null then jsonb_build_object('colOrder', to_jsonb(s.col_order)) else '{}'::jsonb end
      || case when s.removed      is not null then jsonb_build_object('removed', to_jsonb(s.removed))  else '{}'::jsonb end
      || case when s.removed_at   is not null then jsonb_build_object('removedAt', s.removed_at)     else '{}'::jsonb end
      || case when s.trash        is not null then jsonb_build_object('trash', s.trash)             else '{}'::jsonb end
      || case when s.value_colors is not null then jsonb_build_object('valueColors', s.value_colors) else '{}'::jsonb end
      || case when s.col_bold     is not null then jsonb_build_object('colBold', s.col_bold)         else '{}'::jsonb end
      || case when s.stage_colors is not null then jsonb_build_object('stageColors', s.stage_colors) else '{}'::jsonb end)
      from loan_sheet s where s.owner_id = o), '[]'::jsonb));
  end if;
  if 'glossary' = any(want) then
    res := res || jsonb_build_object('glossary', coalesce((select jsonb_agg(g.extra || jsonb_strip_nulls(jsonb_build_object(
      'id', g.id, 'term', g.term, 'body', g.body, 'createdAt', _iso(g.created_at))) order by g.id) from glossary g where g.owner_id = o), '[]'::jsonb));
  end if;
  return res;
end $$;

-- Ba hàm app gọi: luôn làm việc trên dữ liệu của chính người đang đăng nhập.
create or replace function public.load_docs(p_collections text[] default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_active() then raise exception 'Chưa đăng nhập hoặc tài khoản đã bị khoá' using errcode = '42501'; end if;
  return _load_docs(auth.uid(), p_collections);
end $$;
create or replace function public.save_doc(p_collection text, p_id text, p_doc jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_active() then raise exception 'Chưa đăng nhập hoặc tài khoản đã bị khoá' using errcode = '42501'; end if;
  perform _save_doc(auth.uid(), p_collection, p_id, p_doc);
end $$;
-- Lưu nhiều bản ghi một lần (đưa dữ liệu trên máy vào tài khoản): [{collection, id, data}, …]
create or replace function public.save_docs(p_docs jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare e jsonb; n integer := 0;
begin
  if not is_active() then raise exception 'Chưa đăng nhập hoặc tài khoản đã bị khoá' using errcode = '42501'; end if;
  if jsonb_array_length(_arr(p_docs)) > 2000 then raise exception 'Tối đa 2000 bản ghi một lần' using errcode = '22023'; end if;
  for e in select value from jsonb_array_elements(_arr(p_docs)) loop
    perform _save_doc(auth.uid(), e->>'collection', e->>'id', e->'data');
    n := n + 1;
  end loop;
  return n;
end $$;
create or replace function public.delete_doc(p_collection text, p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_active() then raise exception 'Chưa đăng nhập hoặc tài khoản đã bị khoá' using errcode = '42501'; end if;
  perform _delete_doc(auth.uid(), p_collection, p_id);
end $$;

-- ---------- 6. Lịch chung: cửa duy nhất người chưa đăng nhập gọi được ----------
create function public.public_calendar(p_from date, p_to date)
returns table (owner_id uuid, owner_name text, day date, start_time text, end_time text,
               company text, people text[], clients text[], tasks text[])
language plpgsql stable security definer set search_path = public as $$
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'Khoảng ngày không hợp lệ (tối đa 62 ngày)' using errcode = '22023';
  end if;
  return query
  with s as (
    select pr.id, pr.display_name,
      coalesce((select ps.is_public from public_settings ps where ps.owner_id = pr.id and ps.key = 'calendar.busy'), true)     as busy,
      coalesce((select ps.is_public from public_settings ps where ps.owner_id = pr.id and ps.key = 'calendar.company'), false) as co,
      coalesce((select ps.is_public from public_settings ps where ps.owner_id = pr.id and ps.key = 'calendar.people'), false)  as pe,
      coalesce((select ps.is_public from public_settings ps where ps.owner_id = pr.id and ps.key = 'calendar.clients'), false) as cl,
      coalesce((select ps.is_public from public_settings ps where ps.owner_id = pr.id and ps.key = 'calendar.tasks'), false)   as tk
    from profiles pr where pr.status = 'active'
  )
  select t.owner_id, s.display_name, t.work_date, left(t.start_time::text, 5), left(t.end_time::text, 5),
    case when s.co then (select c.name from companies c where c.owner_id = t.owner_id and c.id = t.company_id) end,
    case when s.pe then array(select distinct p.name from task_workers w
      join people p on p.owner_id = w.owner_id and p.id = w.person_id where w.owner_id = t.owner_id and w.task_id = t.id) end,
    case when s.cl then array(select distinct k.name from task_items it
      join clients k on k.owner_id = it.owner_id and k.id = it.client_id where it.owner_id = t.owner_id and it.task_id = t.id) end,
    case when s.tk then array(select it.text from task_items it where it.owner_id = t.owner_id and it.task_id = t.id and it.text <> ''
      order by it.worker_pos, it.position) end
  from tasks t join s on s.id = t.owner_id and s.busy
  where t.work_date between p_from and p_to and t.start_time is not null and t.end_time is not null
  order by 3, 4;
end $$;

-- ---------- 7. Ai được gọi hàm nào ----------
do $$
declare f text;
begin
  -- hàm nội bộ: không ai gọi qua API
  foreach f in array array['public._save_doc(uuid, text, text, jsonb)', 'public._delete_doc(uuid, text, text)', 'public._load_docs(uuid, text[])',
    'public.handle_new_user()'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  -- người đã đăng nhập
  foreach f in array array['public.load_docs(text[])', 'public.save_doc(text, text, jsonb)', 'public.save_docs(jsonb)',
    'public.delete_doc(text, text)', 'public.admin_set_status(uuid, text)', 'public.list_workers()'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- ai cũng gọi được
  execute 'revoke execute on function public.public_calendar(date, date) from public';
  execute 'grant execute on function public.public_calendar(date, date) to anon, authenticated';
end $$;

-- ---------- 8. Chuyển dữ liệu từ bản 2 (app_docs có owner_id), nếu có ----------
do $$
declare r record;
begin
  if to_regclass('public.app_docs') is not null then
    for r in select owner_id, collection, id, data from public.app_docs loop
      perform public._save_doc(r.owner_id, r.collection, r.id, r.data);
    end loop;
    if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_docs') then
      alter publication supabase_realtime drop table public.app_docs;
    end if;
    alter table public.app_docs rename to app_docs_backup;   -- giữ lại để đối chiếu, xoá được khi đã yên tâm
    revoke all on public.app_docs_backup from anon, authenticated;
  end if;
end $$;
