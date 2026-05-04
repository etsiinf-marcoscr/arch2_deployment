from flask import Flask, jsonify, request
from flask_cors import CORS

app = Flask(__name__)
CORS(app)


@app.route("/products", methods=["GET"])
def get_products():
    products = {
        "product_item_arr": [
            {
                "product_name_str": "apple pie slice",
                "product_id_str": "a444",
                "price_in_cents_int": 595,
                "description_str": "amazing taste",
                "tag_str_arr": ["pie slice", "on offer"],
                "special_int": 1
            },
            {
                "product_name_str": "chocolate cake slice",
                "product_id_str": "a445",
                "price_in_cents_int": 595,
                "description_str": "chocolate heaven",
                "tag_str_arr": ["cake slice", "on offer"]
            },
            {
                "product_name_str": "chocolate cake",
                "product_id_str": "a446",
                "price_in_cents_int": 4095,
                "description_str": "chocolate heaven",
                "tag_str_arr": ["whole cake", "on offer"]
            }
        ]
    }

    return jsonify(products)


@app.route("/products/on_offer", methods=["GET"])
def get_products_on_offer():

    products = {
        "product_item_arr": [
            {
                "product_name_str": "apple pie slice",
                "product_id_str": "a444",
                "price_in_cents_int": 595,
                "description_str": "amazing taste",
                "tag_str_arr": ["pie slice", "on offer"],
                "special_int": 1
            }
        ]
    }

    return jsonify(products)

@app.route("/create_report", methods=["POST"])
def create_report():

    data = request.json  # opcional, por si se envían parámetros

    if not data:
        return {"error": "Invalid JSON"}, 400

    # luego irá SQS / Step Functions / ECS task
    report_id = "rep-12345"

    return jsonify({
        "msg_str": "report queued successfully",
        "report_id": report_id,
        "status": "processing"
    }), 202


if __name__ == "__main__":
    app.run(debug=True)