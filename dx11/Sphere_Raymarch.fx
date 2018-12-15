Texture2D texture2d <string uiname="Texture";>;

SamplerState linearSampler : IMMUTABLE
{
	Filter = MIN_MAG_MIP_LINEAR;
	AddressU = Clamp;
	AddressV = Clamp;
};

cbuffer cbPerDraw : register( b0 )
{
	float4x4 tVP : LAYERVIEWPROJECTION;
	float4x4 tVI : VIEWINVERSE;
	float4x4 tPI : PROJECTIONINVERSE;
};

cbuffer cbPerObj : register( b1 )
{
	float4x4 tW : WORLD;
	float4 cAmb <bool color=true;String uiname="Color";> = { 1.0f,1.0f,1.0f,1.0f };
};

struct VS_IN
{
	float4 PosO : POSITION;
	float4 TexCd : TEXCOORD0;
	
};

struct vs2ps
{
	float4 PosWVP: SV_Position;
	float4 TexCd: TEXCOORD0;
};

struct psout{
	float4 color : SV_Target;
	float depth : SV_Depth;
};

vs2ps VS(VS_IN input)
{
	vs2ps output;
	output.PosWVP  = input.PosO;
	output.TexCd = input.TexCd;
	return output;
}

//剰余計算
float3 mod(float3 n, float d){
	return n - (d * floor(n / d));
}

//距離関数のリピート
float3 dRep(float3 p, float c) {
    return mod(p, c) - 0.5 * c;
}

//球の距離関数
float dSphere(float3 rayPosition, float radius){
	return length(rayPosition) - radius;
}

//直方体の距離関数
float dBox( float3 p, float3 b ){
  float3 d = abs(p) - b;
  return length(max(d,0.0))
         + min(max(d.x,max(d.y,d.z)),0.0); // remove this line for an only partially signed sdf 
}

//トーラスの距離関数
float sdTorus( float3 p, float2 t ){
  float2 q = float2(length(p.xz)-t.x,p.y);
  return length(q)-t.y;
}

//シリンダーの距離関数
float sdCappedCylinder( float3 p, float2 h )
{
  float2 d = abs(float2(length(p.xz),p.y)) - h;
  return min(max(d.x,d.y),0.0) + length(max(d,0.0));
}

//メンガーのスポンジ
float dMenger(float3 pos)
{
   float d = dBox(pos, 1.0);

   float s = 1.0;
   for(int m = 0; m < 8; m++){
      float3 a = mod(pos * s, 2.0 ) - 1.0;
      s *= 3.0;
      float3 r = abs(1.0 - 3.0*abs(a));

      float da = max(r.x,r.y);
      float db = max(r.y,r.z);
      float dc = max(r.z,r.x);
      float c = (min(da,min(db,dc))-1.0)/s;

      d = max(d,c);
   }

   return d;
}

float dRecursiveTetrahedron(float3 pos){
    pos = mod(pos / 2, 1.0);

    const float3 a1 = float3( 1.0,  1.0,  1.0);
    const float3 a2 = float3(-1.0, -1.0,  1.0);
    const float3 a3 = float3( 1.0, -1.0, -1.0);
    const float3 a4 = float3(-1.0,  1.0, -1.0);

    const float scale = 2.0;
    float d;
    for (int n = 0; n < 30; ++n) {
        float3 c = a1; 
        float minDist = length(pos - a1);
        d = length(pos - a2); if (d < minDist) { c = a2; minDist = d; }
        d = length(pos - a3); if (d < minDist) { c = a3; minDist = d; }
        d = length(pos - a4); if (d < minDist) { c = a4; minDist = d; }
        pos = scale * pos - c * (scale - 1.0);
    }
 
    return length(pos) * pow(scale, float(-n));
}

//スムースを含む合成
float opSmoothUnion( float d1, float d2, float k ) {
    float h = clamp( 0.5 + 0.5*(d2-d1)/k, 0.0, 1.0 );
    return lerp( d2, d1, h ) - k*h*(1.0-h);
}

//最終的にシーンとなる距離関数
float distFunc(float3 pos){
	return dSphere(dRep(pos, 3.0), 1.0);
}

//法線を取得する関数
float3 getNormal(float3 pos, float rad){
    float ep = 0.0001;
    return normalize(float3(
            distFunc(pos) - distFunc(float3(pos.x - ep, pos.y, pos.z)),
            distFunc(pos) - distFunc(float3(pos.x, pos.y - ep, pos.z)),
            distFunc(pos) - distFunc(float3(pos.x, pos.y, pos.z - ep))
        ));
}

//Ambient Occlusion（環境遮蔽項）を計算する関数
float calcAo(float3 pos, float3 norm){
	float sca = 1.0, occ = 0.0;
	for(float i = 0.0; i < 5.0; i++){
		float hr = 0.05 + i * 0.5;
		float dd = distFunc(norm * hr + pos);
		occ += (hr - dd) * sca;
		sca *= 0.5;
	}
	return saturate(1.0 - occ);
}

float3 LightPos = float3(1.0, -1.0, 1.0); //ライトの位置

psout PS(vs2ps In)//返り値を定義したpsoutに指定。この辺にあったSV_Targetの文字を削除
{
	psout output;
	
	float3 LightDir = normalize(LightPos);
	
	float2 rayDir = (In.TexCd.xy * 2 - 1) * float2(1, -1);
	float3 ray = normalize(mul(float4(mul(float4(rayDir, 0, 0), tPI).xy, 1, 0), tVI).xyz); //カメラ行列を利用してレイを定義
	
	float3 normal;
	float4 col;
	
	float3 rayPos = tVI[3].xyz; //レイの初期位置（カメラの位置）をViewの逆行列から取り出す。
	float dist = 0; //レイとオブジェクト間の最短距離を格納する変数
	float ao = 1.0;
	
	//マーチングループ
	for(int i = 0; i < 64; i++){
		dist = distFunc(rayPos);
		
		//オブジェクトとの距離が一定以下であれば衝突と判定
		if(dist < 0.0001){ 
			normal = getNormal(rayPos, 1.0);//法線を取得
			col = max(dot(normal, LightDir), 0.15);//ランバートシェーディング+Ambient(0.15)
			ao = calcAo(rayPos, normal);//AOの計算
			
			break; //衝突したのであれば、これ以上の処理は必要ないためループから抜ける
		}
		rayPos += ray * dist; //レイの座標を更新
	}
	
	//col *= ao;//AOを乗算
	output.color = col;//構造体内の変数に対して色情報を出力
	
	float4 posw = mul(float4(rayPos, 1), tVP);//ViewProjection行列をかけることでポリゴンモデルと位置の整合性をとる
	output.depth = posw.z / posw.w; //w成分で割ることでzを正規化し、深度値とする

	return output;//構造体を返す
}





technique10 Constant
{
	pass P0 <string format="R16G16B16A16_Float";>
	{
		SetVertexShader( CompileShader( vs_4_0, VS() ) );
		SetPixelShader( CompileShader( ps_4_0, PS() ) );
	}
}




