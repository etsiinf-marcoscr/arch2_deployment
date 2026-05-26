from flask import Flask, jsonify
from flask_cors import CORS
import boto3
from boto3.dynamodb.conditions import Attr

app = Flask(__name__)
CORS(app)

TABLE_NAME = "FoodProducts"
INDEX_NAME = "special_GSI"

dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
table = dynamodb.Table(TABLE_NAME)


def transform_items(data):
    result = []
    for item in data:
        new_item = {
            "product_name_str":    item.get("product_name"),
            "product_id_str":      item.get("product_id"),
            "price_in_cents_int":  int(item.get("price_in_cents", 0)),
            "description_str":     item.get("description"),
            "tag_str_arr":         item.get("tags", [])
        }
        if item.get("special") is not None:
            new_item["special_int"] = int(item["special"])
        result.append(new_item)
    return result


@app.route("/products", methods=["GET"])
def get_products():
    response = table.scan()
    data = response["Items"]
    while "LastEvaluatedKey" in response:
        response = table.scan(ExclusiveStartKey=response["LastEvaluatedKey"])
        data.extend(response["Items"])
    return jsonify({"product_item_arr": transform_items(data)})


@app.route("/products/on_offer", methods=["GET"])
def get_products_on_offer():
    response = table.scan(
        IndexName=INDEX_NAME,
        FilterExpression=Attr("tags").contains("on offer")
    )
    data = response["Items"]
    while "LastEvaluatedKey" in response:
        response = table.scan(
            IndexName=INDEX_NAME,
            ExclusiveStartKey=response["LastEvaluatedKey"],
            FilterExpression=Attr("tags").contains("on offer")
        )
        data.extend(response["Items"])
    return jsonify({"product_item_arr": transform_items(data)})


if __name__ == "__main__":
    app.run(debug=True)