### TFG de Monitorización y Análisis de Arquitecturas Cloud basadas en Contenedores   
#### **Autor: Marcos Casado Ruiz**

## Despliegue básico mediante plantilla de despliegue CloudFormation y bastión (EC2)

**Paso 1**: Crear una VPC (VPC & More) con CIDR 10.0.0.0/16 en 1 AZ (zona de disponibilidad) con una subred pública con CIDR 10.0.0.0/24 en us-east-1a.  
**IMPORTANTE: Marcar la opción "Enable DNS hostnames" en la VPC.**

**Paso 2**: Crear una EC2 **en la misma VPC** creada en el paso 1 y con una IP pública asignada.

**Paso 3**: Instalar git y clonar el repositorio en el bastión Amazon Linux 2023 (EC2):
```bash
   sudo dnf install git -y
   git clone https://github.com/etsiinf-marcoscr/arch2_deployment.git
```

**Paso 4**: Configurar las credenciales AWS (también podría usarse ```aws login```):
```bash
   aws configure
```

**Paso 5**: Exportar la variable de entorno ```EMAIL``` que se le asociará al usuario 'frank' creado en el stack:
```bash
   export EMAIL="tu@email.com"
```

**Paso 6**: Dar permisos de ejecución al script de despliegue y ejecutarlo:
```bash
   cd arch2_deployment/
   chmod +x arch2-setup.sh && ./arch2-setup.sh
```

**Paso 7 (_opcional_)**: Para borrar los recursos desplegados por el script, ejecute el siguiente comando:
```bash
   chmod +x arch2-teardown.sh && ./arch2-teardown.sh
```
_Tenga en cuenta que necesitará eliminar todavía el bastión EC2, el certificado ACM autofirmado y la VPC manualmente desde la consola de AWS en sus respectivos servicios, ya que el script no los borra._
