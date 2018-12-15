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

//��]�v�Z
float3 mod(float3 n, float d){
	return n - (d * floor(n / d));
}

//�����֐��̃��s�[�g
float3 dRep(float3 p, float c) {
    return mod(p, c) - 0.5 * c;
}

//���̋����֐�
float dSphere(float3 rayPosition, float radius){
	return length(rayPosition) - radius;
}

//�����̂̋����֐�
float dBox( float3 p, float3 b ){
  float3 d = abs(p) - b;
  return length(max(d,0.0))
         + min(max(d.x,max(d.y,d.z)),0.0); // remove this line for an only partially signed sdf 
}

//�g�[���X�̋����֐�
float sdTorus( float3 p, float2 t ){
  float2 q = float2(length(p.xz)-t.x,p.y);
  return length(q)-t.y;
}

//�V�����_�[�̋����֐�
float sdCappedCylinder( float3 p, float2 h )
{
  float2 d = abs(float2(length(p.xz),p.y)) - h;
  return min(max(d.x,d.y),0.0) + length(max(d,0.0));
}

//�����K�[�̃X�|���W
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

//�X���[�X���܂ލ���
float opSmoothUnion( float d1, float d2, float k ) {
    float h = clamp( 0.5 + 0.5*(d2-d1)/k, 0.0, 1.0 );
    return lerp( d2, d1, h ) - k*h*(1.0-h);
}

//�ŏI�I�ɃV�[���ƂȂ鋗���֐�
float distFunc(float3 pos){
	return dSphere(dRep(pos, 3.0), 1.0);
}

//�@�����擾����֐�
float3 getNormal(float3 pos, float rad){
    float ep = 0.0001;
    return normalize(float3(
            distFunc(pos) - distFunc(float3(pos.x - ep, pos.y, pos.z)),
            distFunc(pos) - distFunc(float3(pos.x, pos.y - ep, pos.z)),
            distFunc(pos) - distFunc(float3(pos.x, pos.y, pos.z - ep))
        ));
}

//Ambient Occlusion�i���Օ����j���v�Z����֐�
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

float3 LightPos = float3(1.0, -1.0, 1.0); //���C�g�̈ʒu

psout PS(vs2ps In)//�Ԃ�l���`����psout�Ɏw��B���̕ӂɂ�����SV_Target�̕������폜
{
	psout output;
	
	float3 LightDir = normalize(LightPos);
	
	float2 rayDir = (In.TexCd.xy * 2 - 1) * float2(1, -1);
	float3 ray = normalize(mul(float4(mul(float4(rayDir, 0, 0), tPI).xy, 1, 0), tVI).xyz); //�J�����s��𗘗p���ă��C���`
	
	float3 normal;
	float4 col;
	
	float3 rayPos = tVI[3].xyz; //���C�̏����ʒu�i�J�����̈ʒu�j��View�̋t�s�񂩂���o���B
	float dist = 0; //���C�ƃI�u�W�F�N�g�Ԃ̍ŒZ�������i�[����ϐ�
	float ao = 1.0;
	
	//�}�[�`���O���[�v
	for(int i = 0; i < 64; i++){
		dist = distFunc(rayPos);
		
		//�I�u�W�F�N�g�Ƃ̋��������ȉ��ł���ΏՓ˂Ɣ���
		if(dist < 0.0001){ 
			normal = getNormal(rayPos, 1.0);//�@�����擾
			col = max(dot(normal, LightDir), 0.15);//�����o�[�g�V�F�[�f�B���O+Ambient(0.15)
			ao = calcAo(rayPos, normal);//AO�̌v�Z
			
			break; //�Փ˂����̂ł���΁A����ȏ�̏����͕K�v�Ȃ����߃��[�v���甲����
		}
		rayPos += ray * dist; //���C�̍��W���X�V
	}
	
	//col *= ao;//AO����Z
	output.color = col;//�\���̓��̕ϐ��ɑ΂��ĐF�����o��
	
	float4 posw = mul(float4(rayPos, 1), tVP);//ViewProjection�s��������邱�ƂŃ|���S�����f���ƈʒu�̐��������Ƃ�
	output.depth = posw.z / posw.w; //w�����Ŋ��邱�Ƃ�z�𐳋K�����A�[�x�l�Ƃ���

	return output;//�\���̂�Ԃ�
}





technique10 Constant
{
	pass P0 <string format="R16G16B16A16_Float";>
	{
		SetVertexShader( CompileShader( vs_4_0, VS() ) );
		SetPixelShader( CompileShader( ps_4_0, PS() ) );
	}
}




