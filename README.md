TFG de Monitorización y Análisis de Arquitecturas Cloud basadas en Contenedores   
**Autor: Marcos Casado Ruiz**

## Despliegue básico mediante plantilla de despliegue CloudFormation y bastión (EC2)

Paso 1: Crear una VPC (VPC & More) con CIDR 10.0.0.0/16 en 1 AZ (zona de disponibilidad) con una subred pública con CIDR 10.0.0.0/24 en us-east-1a.  
**IMPORTANTE: Marcar la opción "Enable DNS hostnames" en la VPC.**

Paso 2: Ir a CloudFormation y crear un nuevo despliegue (stack).  
- 2.1: Elegir "Upload a template file" y subir el archivo "cloudformation_template.yaml" que se encuentra en este repositorio.  
- 2.2: Rellenar los parámetros del despliegue:  
  - Stack name: "noCF-ECS-arch2" (si se le da otro nombre hay que modificar la variable ```STACK_NAME``` en el sh)  
  - LabRoleArn: Pegar el ARN del rol del laboratorio o de uno personalizado que tenga los permisos necesarios (IAM > Roles > LabRole).  
  - VpcId: Elegir la VPC creada en el paso 1 de entre las disponibles.  
  - PublicSubnetOne: Elegir la subred pública creada en el paso 1.
  - StudentEmail: Introducir un correo electrónico en el que se quieran recibir las notificaciones de SNS (opcional, solo se envían notificaciones mientras el stack esté activo).
- 2.3: Elegir el LabRole de nuevo o el rol personalizado con permisos necesarios para el stack.  
- 2.4: Crear el stack y esperar a que se complete la creación (CREATE_COMPLETE). **Puede tardar de 8 a 12 minutos en completarse.**

Paso 3: Crear una EC2 **en la misma VPC** que el stack creado en el paso 2 y con una IP pública asignada.

Paso 4: Instalar git y clonar el repositorio en un bastion Amazon Linux 2023 (EC2):
```bash
   sudo dnf install git-all -y
   git clone https://github.com/etsiinf-marcoscr/arch2_deployment.git
```

Paso 5: Configurar las credenciales AWS (también ```aws login```):
```bash
   aws configure
```

Paso 6: Exportar la variable de entorno ```EMAIL``` con el correo electrónico introducido en el paso 2 (si se introdujo alguno):
```bash
   export EMAIL="tu@email.com"
```

Paso 7: Dar permisos de ejecución al script de despliegue y ejecutarlo:
```bash
   cd arch2_deployment/
   chmod +x setup_noCF.sh && ./setup_noCF.sh
```
