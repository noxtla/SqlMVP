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
