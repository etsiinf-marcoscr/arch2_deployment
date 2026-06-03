import boto3
import sys

'''
Este script sirve para mandar actualizaciones de inventario de café al topic SNS
para su posterior procesamiento por parte del worker SQS. El formato de cada linea
del fichero de entrada debe ser el siguiente:
<id_producto>:<nombre_producto>:<cantidad>
Siendo id_producto (ejemplo: 1) un identificador unico del producto,
nombre_producto el nombre del producto (ejemplo: "Arabica")
y cantidad un numero entero no negativo (0 - sin stock, >0 - unidades a añadir al stock).

Uso:
python3 send_beans_update.py <nombre_fichero>
Se proveen tres txts de ejemplo (2 invalidos, los primeros, y 1 valido, el último)

Ejemplo de uso:
python3 send_beans_update.py beans_update_3.txt
'''

sns_topic = "<SNS_TOPIC_ARN>"
sns_client = boto3.client('sns')
file_name = sys.argv[1]
file_handle = open(file_name)

for message_data in file_handle:
    message_values = message_data.strip().split(':')
    quantity = int(message_values[2])
    if quantity > 0:
        response = sns_client.publish(
            TopicArn=sns_topic,
            Message=message_data.strip(),
            Subject='New bean delivery',
            MessageGroupId='bean_message_group'
        )
    
        print(response)
    elif quantity == 0:
        response = sns_client.publish(
            TopicArn=sns_topic,
            Message=message_data.strip(),
            Subject='New bean delivery',
            MessageAttributes={
                'inventory_alert': {
                    'DataType': 'String',
                    'StringValue': 'out_of_stock'
                }
            },
            MessageGroupId='bean_message_group'
        )
        
        print(response)
    else:
        print(f"Cantidad invalida en linea: '{message_data.strip()}' - se esperaba un numero entero no negativo")