-- =================================================================
-- GRUPO 1: TABLAS DE CATÁLOGO
-- Propósito: Almacenar opciones predefinidas para garantizar la consistencia
-- de los datos en toda la aplicación. Son simples, pero muy importantes.
-- =================================================================

-- Almacena los posibles cargos (e.g., 'Trimmer', 'Field Manager').
CREATE TABLE positions (
    id SERIAL PRIMARY KEY, -- Un simple número es ideal para un catálogo.
    name TEXT NOT NULL UNIQUE -- El nombre del cargo. Se define como ÚNICO para evitar duplicados.
);

-- Almacena los estados posibles de un empleado (e.g., 'Active', 'Inactive', 'On Leave').
-- CRÍTICO para la lógica de seguridad: solo los 'Active' pueden iniciar sesión.
CREATE TABLE employee_status (
    id SERIAL PRIMARY KEY, -- Un simple número es ideal.
    name TEXT NOT NULL UNIQUE -- El estado. Se define como ÚNICO para evitar duplicados.
);

-- Almacena los estados de la asistencia diaria (e.g., 'Presente', 'Ausente', 'Enfermo').
CREATE TABLE attendance_status (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);


-- =================================================================
-- GRUPO 2: ENTIDADES PRINCIPALES Y OPERACIONALES
-- Propósito: Representan los objetos y acciones centrales del sistema,
-- manteniendo una estructura normalizada y segura.
-- =================================================================

-- Almacena la información demográfica de una persona.
-- Separada de 'employees' para mantener una buena normalización a largo plazo.
CREATE TABLE persons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), -- Usar UUID es más seguro y escalable que un SERIAL para entidades principales.
    full_name TEXT NOT NULL, -- Nombre completo de la persona.
    birth_date DATE NOT NULL, -- Fecha de nacimiento, usada para la verificación de identidad.
    phone_number TEXT UNIQUE, -- CRÍTICO: La GCF buscará por este campo. Debe ser único y estar en formato E.164 (+1555...).
    avatar_url TEXT, -- URL a la foto de perfil almacenada en Supabase Storage (S3). No guardamos el binario aquí.
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Vincula a una 'person' con sus datos específicos de empleado.
-- Contiene la información laboral y de estado actual.
CREATE TABLE employees (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), -- Clave primaria propia para la entidad 'employee'.
    person_id UUID NOT NULL UNIQUE, -- Clave foránea que la vincula a una única persona.
    employee_id TEXT NOT NULL UNIQUE, -- ID legible por humanos (e.g., "EMP123"), para uso interno de la empresa.
    position_id INT NOT NULL, -- El cargo actual del empleado.
    status_id INT NOT NULL, -- El estado actual del empleado (activo/inactivo).
    hire_date DATE NOT NULL, -- Fecha de contratación.
    is_biometric_enabled BOOLEAN NOT NULL DEFAULT FALSE, -- Controla si el usuario ha habilitado el login biométrico en la app.
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- CONSTRAINTS: Definen las reglas de negocio y seguridad directamente en la base de datos.
    -- Se usa ON DELETE RESTRICT como medida de seguridad para evitar eliminaciones accidentales en cadena.
    CONSTRAINT fk_person FOREIGN KEY (person_id) REFERENCES persons(id) ON DELETE RESTRICT,
    CONSTRAINT fk_position FOREIGN KEY (position_id) REFERENCES positions(id) ON DELETE RESTRICT,
    CONSTRAINT fk_status FOREIGN KEY (status_id) REFERENCES employee_status(id) ON DELETE RESTRICT
);

-- Tabla operacional para registrar la asistencia diaria.
CREATE TABLE attendance (
    id BIGSERIAL PRIMARY KEY,
    employee_id UUID NOT NULL, -- Apunta al UUID del 'employee', no de la 'person'.
    attendance_date DATE NOT NULL,
    status_id INT NOT NULL,
    check_in TIMESTAMPTZ, -- Se registra cuando el usuario hace check-in.
    check_out TIMESTAMPTZ, -- Se actualiza cuando el usuario hace check-out.
    
    -- CONSTRAINTS
    CONSTRAINT fk_attendance_employee FOREIGN KEY (employee_id) REFERENCES employees(id) ON DELETE CASCADE, -- Si se borra un empleado, su historial de asistencia se va con él. Esto es lógico.
    CONSTRAINT fk_attendance_status FOREIGN KEY (status_id) REFERENCES attendance_status(id) ON DELETE RESTRICT,
    UNIQUE (employee_id, attendance_date) -- Regla de negocio: Un empleado solo puede tener un registro de asistencia por día.
);


-- =================================================================
-- GRUPO 3: TRIGGERS DE AUTOMATIZACIÓN
-- Propósito: Mantener la consistencia de los datos sin necesidad de
-- lógica adicional en la aplicación.
-- =================================================================

-- Nota: Para que estos triggers funcionen, necesitas habilitar la extensión 'moddatetime'.
-- Ejecuta esto en una nueva consulta en el editor SQL de Supabase: CREATE EXTENSION moddatetime;

-- Trigger para actualizar automáticamente el campo 'updated_at' en la tabla 'persons'.
CREATE TRIGGER handle_persons_updated_at BEFORE UPDATE ON persons 
  FOR EACH ROW EXECUTE PROCEDURE moddatetime (updated_at);

-- Trigger para actualizar automáticamente el campo 'updated_at' en la tabla 'employees'.
CREATE TRIGGER handle_employees_updated_at BEFORE UPDATE ON employees 
  FOR EACH ROW EXECUTE PROCEDURE moddatetime (updated_at);





-- =================================================================
-- GRUPO 4: TABLA DE LECTURA OPTIMIZADA PARA AUTENTICACIÓN
-- Propósito: Proporcionar una vista desnormalizada y ultra-rápida
-- para el proceso de login. Esta es la ÚNICA tabla que la GCF
-- consultará durante la autenticación. Su contenido se genera y
-- actualiza automáticamente a través de triggers.
-- =================================================================

CREATE TABLE auth_users (
    -- La clave primaria es el número de teléfono, ya que es el identificador de entrada del usuario.
    phone_number TEXT PRIMARY KEY,

    -- UUIDs para poder, si es necesario, enlazar de vuelta a las tablas originales.
    employee_uuid UUID NOT NULL,
    person_uuid UUID NOT NULL,
    
    -- Datos desnormalizados para evitar JOINs en tiempo de ejecución.
    full_name TEXT NOT NULL,
    birth_date DATE NOT NULL,
    
    -- Campos CRÍTICOS para la lógica de negocio, pre-calculados.
    status_name TEXT NOT NULL,         -- Directamente 'Active' o 'Inactive'.
    position_name TEXT NOT NULL,       -- Directamente 'Trimmer', 'Manager', etc.
    is_biometric_enabled BOOLEAN NOT NULL,

    -- Sello de tiempo para saber cuándo se actualizó por última vez este registro.
    last_synced_at TIMESTAMPTZ NOT NULL
);

-- Primero, creamos la FUNCIÓN que contiene la lógica de sincronización.
-- Esta función se ejecutará cada vez que un registro en 'employees' sea creado o actualizado.
CREATE OR REPLACE FUNCTION public.sync_auth_user_from_employee()
RETURNS TRIGGER AS $$
DECLARE
    -- Declaramos variables para almacenar los datos que leeremos de las otras tablas.
    person_record RECORD;
    position_record RECORD;
    status_record RECORD;
BEGIN
    -- Obtenemos el registro completo de la persona asociada a este empleado.
    SELECT * INTO person_record FROM public.persons WHERE id = NEW.person_id;
    
    -- Obtenemos el nombre del cargo (position) del empleado.
    SELECT * INTO position_record FROM public.positions WHERE id = NEW.position_id;
    
    -- Obtenemos el nombre del estado (status) del empleado.
    SELECT * INTO status_record FROM public.employee_status WHERE id = NEW.status_id;

    -- Usamos INSERT ... ON CONFLICT para manejar tanto la creación de nuevos usuarios
    -- como la actualización de los existentes en 'auth_users'.
    -- Si ya existe un registro con el mismo 'phone_number', se ejecutará la parte de UPDATE.
    INSERT INTO public.auth_users (
        phone_number,
        employee_uuid,
        person_uuid,
        full_name,
        birth_date,
        status_name,
        position_name,
        is_biometric_enabled,
        last_synced_at
    )
    VALUES (
        person_record.phone_number,
        NEW.id, -- El UUID del empleado que disparó el trigger.
        NEW.person_id,
        person_record.full_name,
        person_record.birth_date,
        status_record.name,
        position_record.name,
        NEW.is_biometric_enabled,
        now() -- La hora actual.
    )
    ON CONFLICT (phone_number) -- Si el número de teléfono ya existe...
    DO UPDATE SET -- ...entonces actualiza los campos.
        employee_uuid = EXCLUDED.employee_uuid,
        person_uuid = EXCLUDED.person_uuid,
        full_name = EXCLUDED.full_name,
        birth_date = EXCLUDED.birth_date,
        status_name = EXCLUDED.status_name,
        position_name = EXCLUDED.position_name,
        is_biometric_enabled = EXCLUDED.is_biometric_enabled,
        last_synced_at = now();

    RETURN NEW; -- Esto es requerido por las funciones de trigger.
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- Ahora, creamos el TRIGGER que vincula la función a las tablas.
-- Este trigger se disparará DESPUÉS de cualquier INSERT o UPDATE en la tabla 'employees'.
CREATE TRIGGER on_employee_change_sync_auth_user
    AFTER INSERT OR UPDATE ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.sync_auth_user_from_employee();


    -- Este UPDATE "toca" cada fila, forzando la ejecución del trigger para cada empleado.
UPDATE employees SET updated_at = now();


SELECT * FROM auth_users;

select * from employees;



///esta es para hacer el rollback
UPDATE employees
SET is_biometric_enabled = false
WHERE id = 'cdbc0ceb-9228-466b-a114-ea29c3f1d9c8';



/*Este es el esquema previo 09 de agosto donde utilizaba el phone number para hacer login, ahora en lugar de phone number vamos a utulizar el numero de empleado*/


/*Este es el codigo que mantiene mi data pero refactoriza la estructura de las tablas, agregamos tambien la imagen secreta aleatoria para eliminar el OTC*/


-- =================================================================
-- PASO 1.1: AÑADIR LA COLUMNA DE IMAGEN SECRETA A `employees`
-- Propósito: Preparamos la tabla principal de empleados para almacenar
-- el identificador de la imagen secreta. Se permite que sea NULL para
-- manejar el caso del primer login (enrollment).
-- =================================================================

-- Usamos "IF NOT EXISTS" para que el script se pueda ejecutar de forma segura
-- incluso si la columna ya fue creada en un intento anterior.
ALTER TABLE public.employees
ADD COLUMN IF NOT EXISTS security_image_identifier TEXT NULL;


-- =================================================================
-- PASO 1.2: ELIMINAR LOS OBJETOS DE AUTENTICACIÓN ANTIGUOS
-- Propósito: Para garantizar una refactorización limpia y sin conflictos,
-- eliminamos la tabla `auth_users` y su lógica de sincronización asociada.
-- =================================================================

DROP TRIGGER IF EXISTS on_employee_change_sync_auth_user ON public.employees;
DROP FUNCTION IF EXISTS public.sync_auth_user_from_employee();
DROP FUNCTION IF EXISTS public.sync_auth_user_from_employee_id(); -- Incluimos esta por si se creó en pruebas
DROP TABLE IF EXISTS public.auth_users;


-- =================================================================
-- PASO 1.3: RE-CREAR LA TABLA `auth_users` CON LA ESTRUCTURA FINAL
-- Propósito: Definir la tabla optimizada para el login, centrada en
-- `employee_id` y con todos los campos necesarios para el flujo de
-- autenticación por pasos.
-- =================================================================

CREATE TABLE public.auth_users (
    -- Clave Primaria: El identificador de entrada para el usuario.
    employee_id TEXT PRIMARY KEY,

    -- UUIDs para enlaces internos y operaciones de escritura.
    employee_uuid UUID NOT NULL UNIQUE,
    person_uuid UUID NOT NULL,

    -- Datos desnormalizados para evitar JOINs durante el login.
    full_name TEXT NOT NULL,
    birth_date DATE NOT NULL,
    
    -- CAMPO CLAVE: Identificador de la imagen de seguridad del usuario.
    -- Es NULL si el usuario nunca ha completado el primer login.
    security_image_identifier TEXT,

    -- Campos CRÍTICOS para la lógica de negocio, pre-calculados.
    status_name TEXT NOT NULL,
    position_name TEXT NOT NULL,
    is_biometric_enabled BOOLEAN NOT NULL,

    -- Sello de tiempo para auditoría y depuración.
    last_synced_at TIMESTAMPTZ NOT NULL
);

-- Creamos un índice en employee_uuid para búsquedas inversas eficientes si fueran necesarias.
CREATE INDEX idx_auth_users_employee_uuid ON public.auth_users(employee_uuid);


-- =================================================================
-- PASO 1.4: CREAR LA FUNCIÓN Y EL TRIGGER DE SINCRONIZACIÓN ACTUALIZADOS
-- Propósito: Definir la lógica que mantendrá la nueva tabla `auth_users`
-- actualizada automáticamente.
-- =================================================================

CREATE OR REPLACE FUNCTION public.sync_auth_user_on_employee_change()
RETURNS TRIGGER AS $$
DECLARE
    person_record RECORD;
    position_record RECORD;
    status_record RECORD;
BEGIN
    -- Obtenemos los registros relacionados de las tablas de catálogo y personas.
    SELECT * INTO person_record FROM public.persons WHERE id = NEW.person_id;
    SELECT name INTO position_record FROM public.positions WHERE id = NEW.position_id;
    SELECT name INTO status_record FROM public.employee_status WHERE id = NEW.status_id;

    -- Usamos INSERT ... ON CONFLICT para manejar la creación y actualización
    -- de forma atómica, basándonos en la clave primaria `employee_id`.
    INSERT INTO public.auth_users (
        employee_id,
        employee_uuid,
        person_uuid,
        full_name,
        birth_date,
        security_image_identifier, -- Incluimos el nuevo campo.
        status_name,
        position_name,
        is_biometric_enabled,
        last_synced_at
    )
    VALUES (
        NEW.employee_id,
        NEW.id,
        NEW.person_id,
        person_record.full_name,
        person_record.birth_date,
        NEW.security_image_identifier, -- Tomamos el valor de la tabla `employees`.
        status_record.name,
        position_record.name,
        NEW.is_biometric_enabled,
        now()
    )
    ON CONFLICT (employee_id)
    DO UPDATE SET
        employee_uuid = EXCLUDED.employee_uuid,
        person_uuid = EXCLUDED.person_uuid,
        full_name = EXCLUDED.full_name,
        birth_date = EXCLUDED.birth_date,
        security_image_identifier = EXCLUDED.security_image_identifier,
        status_name = EXCLUDED.status_name,
        position_name = EXCLUDED.position_name,
        is_biometric_enabled = EXCLUDED.is_biometric_enabled,
        last_synced_at = now();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Creamos el TRIGGER que vincula la función a la tabla 'employees'.
-- Se ejecutará DESPUÉS de cualquier INSERT o UPDATE.
CREATE TRIGGER on_employee_change_sync_auth_user
    AFTER INSERT OR UPDATE ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.sync_auth_user_on_employee_change();


-- =================================================================
-- PASO 1.5: RE-SINCRONIZAR TODOS LOS DATOS EXISTENTES
-- Propósito: Poblar la nueva tabla `auth_users` con los datos de todos
-- los empleados que ya existen en el sistema.
-- =================================================================

-- "Tocamos" cada fila para forzar la ejecución del trigger, asegurando
-- que la tabla `auth_users` se pueble con la lógica de negocio correcta.
UPDATE public.employees SET updated_at = now();

/*Solo para agregar el resumen*/
