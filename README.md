# Despliegue de aplicaciones en AWS: EC2 + RDS

Arquitectura: una instancia EC2 en una **subred pública** ejecuta la aplicación en Docker detrás de Nginx. La base de datos es un **RDS en una subred privada**.

Aplicaciones disponibles:

| Aplicación | Motor RDS | Puerto BD | Base de datos | Script |
|---|---|---|---|---|
| WordPress | MySQL | 3306 | `wordpress` | `wordpress-userdata.sh` |
| Wiki.js | PostgreSQL | 5432 | `wikijs` | `wikijs-userdata.sh` |
| Gitea | PostgreSQL | 5432 | `gitea` | `gitea-userdata.sh` |
| Redmine | PostgreSQL | 5432 | `redmine` | `redmine-userdata.sh` |

---

## 1. Red (VPC)

1. Crear una VPC `10.0.0.0/16`.
2. Crear 4 subredes:
   - Pública AZ A: `10.0.0.0/24`
   - Pública AZ B: `10.0.1.0/24`
   - Privada AZ A: `10.0.2.0/24`
   - Privada AZ B: `10.0.3.0/24`
3. Crear un **Internet Gateway** y asociarlo a la VPC.
4. En la tabla de rutas de las **subredes públicas**, agregar la ruta `0.0.0.0/0 → igw-...`.
5. En las subredes públicas, activar **Asignar automáticamente IPv4 pública**.
6. Las subredes privadas **no** deben tener ruta al Internet Gateway.

## 2. Security Groups

**`sg-app-ec2`** (para la EC2)

| Tipo | Puerto | Origen |
|---|---|---|
| SSH | 22 | Mi IP |
| HTTP | 80 | 0.0.0.0/0 |

Salida: todo el tráfico (la regla por defecto).

**`sg-app-rds`** (para RDS)

| Tipo | Puerto | Origen |
|---|---|---|
| MySQL/Aurora **o** PostgreSQL | 3306 **o** 5432 | `sg-app-ec2` |

El origen debe ser el Security Group de la EC2, no una IP.

## 3. Base de datos (RDS)

1. Crear un **DB Subnet Group** con las dos subredes privadas.
2. Crear la instancia RDS:
   - Motor: **MySQL** (WordPress) o **PostgreSQL** (Wiki.js, Gitea, Redmine).
   - Plantilla: capa gratuita o *Dev/Test*.
   - Usuario maestro: `admin` (MySQL) o `postgres` (PostgreSQL), y una contraseña.
   - VPC: la creada; DB Subnet Group: el del paso anterior.
   - **Acceso público: No.**
   - Security Group: `sg-app-rds`.
3. **Crear la base de datos a mano.** Es obligatorio, porque el script no la crea. En *Configuración adicional → Nombre de base de datos inicial*, escribir el nombre de la tabla de arriba (por ejemplo `gitea`).
4. Esperar a que el estado sea **Disponible** y copiar el **Punto de enlace** (endpoint).

## 4. Preparar el script

Abrir el script de la aplicación y editar las variables del inicio:

```bash
DB_HOST="endpoint-copiado-de-rds"
DB_PORT="5432"            # 3306 para WordPress
DB_NAME="gitea"           # el nombre de la base creada a mano
DB_USER="postgres"        # admin para WordPress
DB_PASSWORD="tu-clave"
```

Revisar que `#!/bin/bash` sea la **primera línea**, sin espacios antes.

## 5. Crear la EC2

1. AMI: **Ubuntu Server** (LTS).
2. Tipo: **t3.small** o superior.
3. Par de claves: el propio.
4. Red: la VPC creada, **subred pública AZ A**, con IP pública **habilitada**.
5. Security Group: `sg-app-ec2`.
6. *Detalles avanzados → Datos de usuario*: pegar el script editado.
7. Lanzar la instancia.

## 6. Verificar

La instalación tarda de **5 a 10 minutos** después de lanzar la instancia.

Por SSH:

```bash
sudo tail -f /var/log/app-setup.log   # avance de la instalación
sudo docker ps                         # el contenedor debe estar "Up"
sudo docker logs NOMBRE --tail 50      # wordpress / wikijs / gitea / redmine
```

Cuando aparezca el mensaje final `... instalado`, abrir en el navegador:

```
http://IP_PUBLICA_EC2
```

Usar `http://`, no `https://`.

---

## Primer acceso por aplicación

### WordPress
- Se abre el asistente de instalación: elegir idioma, título del sitio, usuario administrador y contraseña.
- Panel de administración: `http://IP/wp-admin`.

### Wiki.js
- Se abre el asistente: correo y contraseña del administrador, y la URL del sitio (`http://IP_PUBLICA`).

### Gitea
- Se abre la página de configuración inicial, ya rellenada con los datos de la base. Pulsar **Instalar Gitea**.
- Luego **Registrarse**: el **primer usuario** registrado queda como administrador.
- Los repositorios se clonan por HTTP (el SSH de Git está desactivado).

### Redmine
- Usuario `admin`, contraseña `admin`. Pide cambiarla al entrar.
- Los roles, estados y trackers ya vienen cargados en español.

---

## Problemas frecuentes

| Síntoma | Causa probable |
|---|---|
| El navegador dice "No se puede acceder al sitio" y SSH no conecta | La EC2 está en una subred sin ruta al Internet Gateway o sin IP pública |
| Aparece la página de bienvenida de Nginx | El script todavía está trabajando, o se detuvo: revisar el log |
| El log se queda en `Esperando RDS...` | Endpoint mal copiado, o `sg-app-rds` no permite el puerto desde `sg-app-ec2` |
| El log dice `ERROR: no se pudo conectar a la base` | La base no se creó a mano, el nombre no coincide, o el usuario/clave son incorrectos |
| `502 Bad Gateway` | La aplicación no arrancó: revisar `sudo docker logs NOMBRE` |
| El sitio deja de cargar tras detener e iniciar la EC2 | Cambió la IP pública: asignar una **Elastic IP** |

**Nota:** el script (user-data) solo se ejecuta en el **primer arranque**. Si se corrige algo en AWS después de un fallo, lo más simple es terminar la instancia y crear una nueva.
