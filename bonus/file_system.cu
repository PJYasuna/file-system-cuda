﻿#include "file_system.h"
#include <cuda.h>
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>


// fcb
// byte 0: 0x40 means read; 0x80means write
// byte 1-20: name
// byte 21-22 address
// byte 23-26 size (4 byte for 1024kb max file)
// byte 27-28 created time
// byte 29-30 modified time
#define PERMISSION 0
#define NAME 1
#define ADDR 21 // 2 byte, 0~32kb, represent the address of bitmap or block
#define SIZE 23
#define C_TIME 26
#define M_TIME 28
#define PARENT 30


__device__ __managed__ int gtime = 0;
__device__ __managed__ u32 free_position = 0;
__device__ __managed__ int current_position = 1024;

__device__ int fcb_attribute_addr(FileSystem *fs, int i, int offset);

__device__ void fs_init(FileSystem *fs, uchar *volume, int SUPERBLOCK_SIZE,
							int FCB_SIZE, int FCB_ENTRIES, int VOLUME_SIZE,
							int STORAGE_BLOCK_SIZE, int MAX_FILENAME_SIZE, 
							int MAX_FILE_NUM, int MAX_FILE_SIZE, int FILE_BASE_ADDRESS)
{
  // init variables
  fs->volume = volume;

  // init constants
  fs->SUPERBLOCK_SIZE = SUPERBLOCK_SIZE;
  fs->FCB_SIZE = FCB_SIZE;
  fs->FCB_ENTRIES = FCB_ENTRIES;
  fs->STORAGE_SIZE = VOLUME_SIZE;
  fs->STORAGE_BLOCK_SIZE = STORAGE_BLOCK_SIZE;
  fs->MAX_FILENAME_SIZE = MAX_FILENAME_SIZE;
  fs->MAX_FILE_NUM = MAX_FILE_NUM;
  fs->MAX_FILE_SIZE = MAX_FILE_SIZE;
  fs->FILE_BASE_ADDRESS = FILE_BASE_ADDRESS;

  for (int i = 0; i < 1024; i++) {
    fs->volume[fcb_attribute_addr(fs,i,PERMISSION)] = 0;
  }
}



__device__ int fcb_attribute_addr(FileSystem *fs, int i, int offset) {
  return fs->SUPERBLOCK_SIZE + fs->FCB_SIZE * i + offset;
}

__device__ int get_value(FileSystem *fs, int i, int offset) {
  int ans = 0;
  if (offset == M_TIME || offset == ADDR || offset == PARENT) {
    ans += fs->volume[fcb_attribute_addr(fs, i, offset)] * 256;
    ans += fs->volume[fcb_attribute_addr(fs, i, offset + 1)];
  }
  if (offset == SIZE) {
    ans += fs->volume[fcb_attribute_addr(fs,i,SIZE)] * (256 * 256);
    ans += fs->volume[fcb_attribute_addr(fs,i,SIZE+1)] * 256;
    ans += fs->volume[fcb_attribute_addr(fs,i,SIZE+2)];
  }
  if (offset == PERMISSION) {
    ans += fs->volume[fcb_attribute_addr(fs,i,PERMISSION)];
  }
  return ans;
}

__device__ void set_size(FileSystem *fs, int fp, int size) {
  fs->volume[fcb_attribute_addr(fs,fp,SIZE)] = size / (256 * 256);
  fs->volume[fcb_attribute_addr(fs,fp,SIZE+1)] = size / 256;
  fs->volume[fcb_attribute_addr(fs,fp,SIZE+2)] = size % 256;
}



__device__ int string_compare(FileSystem* fs, int index, char * s2) {
  int ans = 0;
  for (int j = 0; j < 20; j++) {
    ans++;

    if (fs->volume[fcb_attribute_addr(fs,index,NAME) + j] != s2[j]) return 0;
    if (s2[j] == '\0') return ans;
  }

}

__device__ int block_addr(FileSystem *fs, int i) {
  return get_value(fs,i,ADDR) * fs->STORAGE_BLOCK_SIZE + fs->FILE_BASE_ADDRESS;
}

// __device__ void printname(uchar* s) {
//   while (*s != '\0') {
// 		printf("%c", *s);
// 		s++;
// 	}
// }

__device__ char* get_name(FileSystem *fs, int fp) {
  char ans[20];
	for (int i = 0; i < fs->MAX_FILENAME_SIZE; i++) {
		ans[i] = fs->volume[fcb_attribute_addr(fs,fp,NAME + i)];
		if (fs->volume[fcb_attribute_addr(fs,fp,NAME + i)] == '\0') break; // finish setting name
	}
	return ans;
}

__device__ void update_bitmap(FileSystem *fs, int addr, int res) {
  int byte_addr = addr / 8;
  int bit_addr = addr % 8;
  uchar tmp = 0x1 << bit_addr;
  if (res == 1) {
    fs->volume[byte_addr] |= tmp;
  }
  else {
    tmp = ~tmp;
    fs->volume[byte_addr] &= tmp;
  }
}

__device__ u32 my_write(FileSystem *fs, uchar* input, u32 size, u32 fp) {
  // set address
  fs->volume[fcb_attribute_addr(fs,fp,ADDR)] = free_position / 256;
  fs->volume[fcb_attribute_addr(fs,fp,ADDR+1)] = free_position % 256;
  // set size
  set_size(fs,fp,size);

  // set time
  fs->volume[fcb_attribute_addr(fs,fp,M_TIME)] = gtime / 256;
  fs->volume[fcb_attribute_addr(fs,fp,M_TIME+1)] = gtime % 256;

  // write into blocks
  for (int i = 0; i < size; i++) {
    fs->volume[block_addr(fs,fp) + i] = input[i];
  }

  //set bit map
  int block_num = size / fs->STORAGE_BLOCK_SIZE; // 32
  if (size % fs->STORAGE_BLOCK_SIZE != 0) block_num += 1;
  // int start = fcb_attribute_addr(fs,fp,ADDR) * 256;
  // start += fcb_attribute_addr(fs,fp,ADDR + 1);

  int start = get_value(fs,fp,ADDR);

  for (int i = 0; i < block_num; i++) {
    update_bitmap(fs, start + i, 1);
  }


}



__device__ int find_fcb_with_addr(FileSystem *fs, int addr) {
   for (int i = 0; i < 1024; i++) {
        int tmp_addr = get_value(fs,i,ADDR);
        if (tmp_addr == addr) {
            return i;
        }   
    }
    return 1024;
}

__device__ void clean(FileSystem *fs, int fp) {

    int start = get_value(fs,fp,ADDR);
    int size = get_value(fs,fp,SIZE);

    int blocks = size / fs->STORAGE_BLOCK_SIZE; // 32
    if (size % fs->STORAGE_BLOCK_SIZE != 0) blocks += 1;

    // -----------below is compact---------------
  
    // update bitmap
    int current_blocks = free_position - blocks; // 32

    for (int i = 0; i < current_blocks; i++) {
        update_bitmap(fs, i, 1);
    }

    for (int i = current_blocks; i < free_position; i++) {
        update_bitmap(fs, i, 0);
    }

    int start_addr = block_addr(fs, fp);
    for (int i = start; i < current_blocks; i++) {
        for (int j = 0; j < 32; j++) {
          fs->volume[start_addr + i * 32 + j] = fs->volume[start_addr + (i + blocks) * 32 + j];
        }

        int fcb_index = find_fcb_with_addr(fs,i+blocks);
        if (fcb_index != 1024) {
          fs->volume[fcb_attribute_addr(fs,fcb_index,ADDR)] = fs->volume[fcb_attribute_addr(fs,i,ADDR)];
          fs->volume[fcb_attribute_addr(fs,fcb_index,ADDR + 1)] = fs->volume[fcb_attribute_addr(fs,i,ADDR + 1)];
        }

    }

    free_position -= blocks;

}

__device__ void update_parent_size(FileSystem *fs, int fp, int size) {
  
  if (current_position != 1024) {
    int old_size = get_value(fs, current_position, SIZE);
    old_size += size;
    set_size(fs,current_position,old_size);

    // int p_current_position = get_value(fs,current_position,PARENT);

    // if (p_current_position != 1024) {
    //   int old_size = get_value(fs, p_current_position, SIZE);
    //   old_size += size;
    //   set_size(fs,p_current_position,old_size);
    // }
  }
}
    



__device__ u32 fs_open(FileSystem *fs, char *s, int op)
{
	/* Implement open operation here */
  gtime++;
  u32 fp;
  int found = 0;

  // found process
  for (int i = 0; i < 1024; i++) {
    if (fs->volume[fcb_attribute_addr(fs,i,PERMISSION)] != 0) { // have exist a file
      // check if the name matches
      if (string_compare(fs, i, s) && get_value(fs,i,PARENT) == current_position) {
        found = 1;
        fp = i;
        break;
      }
    }
  }
  // if this file exist
  if (found == 1) {
    // read after write, change 10000000 to 11000000
    if (op == G_READ) {
      fs->volume[fcb_attribute_addr(fs,fp,PERMISSION)] = 0xc0;
    }
    if (op == G_WRITE) {
      clean(fs,fp);
    }
    
    return fp;
  }

  // if not exist
  else {
    if (op == G_READ) printf("No file found for read\n");

    else if (op == G_WRITE) {
      // find empty postion
      int empty = -1;
      for(int i = 0; i < 1024; i++) {
        if(fs->volume[fcb_attribute_addr(fs,i,PERMISSION)] == 0) {
          empty = i;
          break;
        }
      }
      // if don't have empty
      if (empty == -1) printf("Can't open! Too much file\n");

      // if have empty
      else {
        fp = empty;
        fs->volume[fcb_attribute_addr(fs,fp,PERMISSION)] = 0x80;
        int name_size = 0;
        // set name
        for (int i = 0; i < 20; i++) {
		      fs->volume[fcb_attribute_addr(fs,fp,NAME + i)] = s[i];
          name_size++;
		      if (s[i] == '\0') break;
	      }

        //set address
        fs->volume[fcb_attribute_addr(fs,fp,ADDR)] = 0;
        fs->volume[fcb_attribute_addr(fs,fp,ADDR+1)] = 0;

        //set size
        set_size(fs,fp,0);
        
        // set creat time
        fs->volume[fcb_attribute_addr(fs,fp,C_TIME)] = gtime / 256;
        fs->volume[fcb_attribute_addr(fs,fp,C_TIME+1)] = gtime % 256;

        // set modified time
        fs->volume[fcb_attribute_addr(fs,fp,M_TIME)] = gtime / 256;
        fs->volume[fcb_attribute_addr(fs,fp,M_TIME+1)] = gtime % 256;


        // set its parent
        // link to its parent
        fs->volume[fcb_attribute_addr(fs,fp,PARENT)] = current_position / 256;
        fs->volume[fcb_attribute_addr(fs,fp,PARENT+1)] = current_position % 256;
        if (current_position != 1024) {
          // update_parent_size
          update_parent_size(fs,fp,name_size);

          fs->volume[fcb_attribute_addr(fs,current_position,M_TIME)] = gtime / 256;
          fs->volume[fcb_attribute_addr(fs,current_position,M_TIME+1)] = gtime % 256;
        }
        

        return fp;
      }
    }

    // wrong parameter
    else printf("Wrong paramater for operation\n"); 
  }

}


__device__ void fs_read(FileSystem *fs, uchar *output, u32 size, u32 fp)
{
  gtime++;
  if (fs->volume[fcb_attribute_addr(fs,fp,PERMISSION)] & 0x40 != 0x40) {
    printf("Can't read! Don't have read permission.\n");
    return;
  }
  else {
    int address = block_addr(fs,fp);
    for (int i = 0; i < size; i++) {
      output[i] = fs->volume[address + i];
      printf("");
    }
  }
}



__device__ u32 fs_write(FileSystem *fs, uchar* input, u32 size, u32 fp)
{
  gtime++;
  // printf("%d\n", fp);

  if (fs->volume[fcb_attribute_addr(fs,fp,PERMISSION)] & 0x80 != 0x80) {
    printf("Can't write! Don't have write permission.\n");
    return;
  }
  else {
    int blocks = size / fs->STORAGE_BLOCK_SIZE; // 32
    if (size % fs->STORAGE_BLOCK_SIZE != 0) blocks += 1;
    
    // If no enough room
    if (1024 * 1024 - free_position * 32 < size) {
        printf("%d\n", free_position * 32);
        printf("Can't write! the file size exceed the limit\n");
    }
   
    else {
      my_write(fs,input,size,fp);
      free_position += blocks;

    }
  }
  return 0;
}

__device__ void fs_gsys(FileSystem *fs, int op)
{
  gtime++;

  int fp[1024];
  int count = 0;
  for (int i = 0; i < 1024; i++) {
    if (fs->volume[fcb_attribute_addr(fs,i,PERMISSION)] != 0 && get_value(fs,i,PARENT) == current_position) {
      fp[count] = i;
      count += 1;
    }
  }

	if (op == LS_D) { // sort by modified time
    printf("===sort by modified time===\n");

    for (int i = 0; i < count; i++) {
      for (int j = 0; j < count - 1; j++) {
        if (get_value(fs,fp[j],M_TIME) < get_value(fs,fp[j + 1],M_TIME)) {
          int tmp = fp[j];
          fp[j] = fp[j+1];
          fp[j+1] = tmp;
        }
      }
    }

    for (int i = 0; i < count; i++) {
        if (get_value(fs,fp[i],PERMISSION) != 2) printf("%s\n", get_name(fs,fp[i]));
        else printf("%s d\n", get_name(fs,fp[i]));
    }
  }

  else if (op == LS_S) {
    printf("===sort by size===\n");
    for (int i = 0; i < count; i++) {
      for (int j = 0; j < count - 1; j++) {
        if (get_value(fs,fp[j],SIZE) < get_value(fs,fp[j + 1],SIZE)) {
          int tmp = fp[j];
          fp[j] = fp[j+1];
          fp[j+1] = tmp;
        }
        else if (get_value(fs,fp[j],SIZE) == get_value(fs,fp[j+1],SIZE) && get_value(fs,fp[j],C_TIME) > get_value(fs,fp[j+1],C_TIME)) {
          int tmp = fp[j];
          fp[j] = fp[j+1];
          fp[j+1] = tmp;
        }
      }
    }

    for (int i = 0; i < count; i++) {
        if (get_value(fs,fp[i],PERMISSION) != 2) printf("%s %d\n", get_name(fs,fp[i]), get_value(fs,fp[i],SIZE));
        else printf("%s %d d\n", get_name(fs,fp[i]), get_value(fs,fp[i],SIZE));
    }
  }

  else if (op == CD_P) {
    current_position = get_value(fs,current_position,PARENT);
  }
  else if (op == PWD) {
    int parent1_position = get_value(fs,current_position,PARENT);
    if (parent1_position != 1024) printf("/%s",get_name(fs,parent1_position));
    printf("/%s\n",get_name(fs,current_position));

  }
  else printf("Wrong operation!\n");
}

__device__ void remove_rs(FileSystem *fs, int fp) {
  // printf("start move\n");
  // printf("the permission is %d\n", get_value(fs,fp,PERMISSION));
  if (get_value(fs,fp,PERMISSION) == 0x02) {
    for (int i = 0; i < 1024; i++) {
      if (get_value(fs,i,PARENT) == fp) {
        if (get_value(fs,i,PERMISSION) != 0x02) {
          fs->volume[fcb_attribute_addr(fs,i,PERMISSION)] = 0;
          clean(fs,i);
        }
        else {
          //still have directory
          for (int j = 0; j < 1024; i++) {
            if (get_value(fs,i,PARENT) == i) {
              fs->volume[fcb_attribute_addr(fs,i,PERMISSION)] = 0;
              clean(fs,i);
            } 
          }
        }
      }
    }
  }
  fs->volume[fcb_attribute_addr(fs,fp,PERMISSION)] = 0;
  clean(fs,fp);

}

__device__ void fs_gsys(FileSystem *fs, int op, char *s)
{
    gtime++;

    int fp = -1;
    int name_size = 0;
    for(int i = 0; i < 1024; i++) {
      // if(string_compare(fs, i, s)) {
      //   printf("its parent %d\n", get_value(fs,i,PARENT));
      //   printf("current_position %d\n", current_position);
      //   printf("i %d\n", i);
      // }
      if(string_compare(fs, i, s) && get_value(fs,i,PARENT) == current_position) {
        name_size = string_compare(fs,i,s);
        fp = i;
        break;
      }
    }


 
    if (op == RM) {
      if (fp == -1) printf("can not find this file or directory\n");
      else {
        fs->volume[fcb_attribute_addr(fs,fp,PERMISSION)] = 0;
        clean(fs,fp);
        update_parent_size(fs,fp,-name_size);
      }
    } 
    else if (op == MKDIR) {
      if (fp != -1) printf("The directory has already exist\n");
      else {

        int empty = -1;
        for(int i = 0; i < 1024; i++) {
          if(fs->volume[fcb_attribute_addr(fs,i,PERMISSION)] == 0) {
            empty = i;
            break;
          }
        }
        fp = empty;
    
        // printf("%d\n", fp);

        fs->volume[fcb_attribute_addr(fs,fp,PERMISSION)] = 0x02;

        int name_size = 0;
        // set name
        for (int i = 0; i < 20; i++) {
          fs->volume[fcb_attribute_addr(fs,fp,NAME + i)] = s[i];
          name_size++;
          if (s[i] == '\0') break;
        }
        //set address
        fs->volume[fcb_attribute_addr(fs,fp,ADDR)] = 0;
        fs->volume[fcb_attribute_addr(fs,fp,ADDR+1)] = 0;

        //set size
        set_size(fs,fp,0);
        
        // set creat time
        fs->volume[fcb_attribute_addr(fs,fp,C_TIME)] = gtime / 256;
        fs->volume[fcb_attribute_addr(fs,fp,C_TIME+1)] = gtime % 256;

        // set modified time
        fs->volume[fcb_attribute_addr(fs,fp,M_TIME)] = gtime / 256;
        fs->volume[fcb_attribute_addr(fs,fp,M_TIME+1)] = gtime % 256;

        // set its parent
        // link to its parent
        fs->volume[fcb_attribute_addr(fs,fp,PARENT)] = current_position / 256;
        fs->volume[fcb_attribute_addr(fs,fp,PARENT+1)] = current_position % 256;

        if (current_position != 1024) {
        // update_parent_size
        update_parent_size(fs,fp,name_size);

        fs->volume[fcb_attribute_addr(fs,current_position,M_TIME)] = gtime / 256;
        fs->volume[fcb_attribute_addr(fs,current_position,M_TIME+1)] = gtime % 256;
        }

      }
    }

    else if (op == CD) {
      if (fp == -1) printf("can not find this file or directory\n");
      if (get_value(fs,fp,PARENT) != current_position) printf("can not find this directory\n");
      else {
        current_position = fp;
      }
    }
    else if (op == RM_RF) {
      if (fp == -1) printf("can not find this file or directory\n");
      else {
        // fs->volume[fcb_attribute_addr(fs,fp,PERMISSION)] = 0;
        remove_rs(fs, fp);
        update_parent_size(fs,fp,-name_size);
      }
    }
    
    else printf("Wrong operation!\n");
  

}
